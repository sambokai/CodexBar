defineProvider({
  id: "huggingface",
  name: "Hugging Face",
  endpoints: ["https://huggingface.co"],
  auth: { type: "bearer", secret: "HF_TOKEN" },
  settings: [{ key: "HF_TOKEN", title: "API token", type: "secure" }],
  capabilities: ["http-status"],

  async fetchUsage(ctx) {
    const root = "https://huggingface.co";

    function parseFailure(message) {
      throw ctx.fail.parseFailure(`Could not parse Hugging Face billing data: ${message}`);
    }

    function object(value, field) {
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        parseFailure(`${field} must be an object`);
      }
      return value;
    }

    function requiredString(value, field) {
      if (typeof value !== "string" || !value.trim()) {
        parseFailure(`${field} must be a non-empty string`);
      }
      return value.trim();
    }

    function optionalString(value, field) {
      if (value === null || value === undefined) return null;
      if (typeof value !== "string") parseFailure(`${field} must be a string`);
      const trimmed = value.trim();
      return trimmed || null;
    }

    function classifyStatus(status, resource) {
      if (status === 401) {
        if (resource === "billing") {
          throw ctx.fail.authenticationExpired("Hugging Face rejected access to personal billing usage.");
        }
        throw ctx.fail.authenticationExpired("Hugging Face rejected the user access token.");
      }
      if (resource === "billing" && status === 403) {
        throw ctx.fail.permissionDenied("Hugging Face denied access to personal billing usage.");
      }
      if (resource === "billing" && status === 404) {
        throw ctx.fail.apiFailure("Hugging Face personal billing usage was not found.");
      }
      if (status === 429) {
        throw ctx.fail.rateLimited("Hugging Face rate limit exceeded. Usage will refresh on the next cycle.");
      }
      if (status >= 500 && status <= 599) {
        throw ctx.fail.providerUnavailable(`Hugging Face ${resource} API returned HTTP ${status}.`);
      }
      if (status < 200 || status >= 300) {
        throw ctx.fail.apiFailure(`Hugging Face ${resource} API returned HTTP ${status}.`);
      }
    }

    async function getJSON(url, resource) {
      const response = await ctx.http.get(url);
      classifyStatus(response.status, resource);
      try {
        return JSON.parse(response.bodyText);
      } catch {
        parseFailure(`${resource} response was not valid JSON`);
      }
    }

    function parsePeriod(period, field) {
      const value = object(period, field);
      const periodStartText = requiredString(value.periodStart, `${field}.periodStart`);
      const periodEndText = requiredString(value.periodEnd, `${field}.periodEnd`);
      let periodStart;
      let periodEnd;
      try {
        periodStart = ctx.date.iso(periodStartText);
        periodEnd = ctx.date.iso(periodEndText);
      } catch {
        parseFailure(`${field}.periodStart and ${field}.periodEnd must be valid ISO-8601 dates`);
      }
      if (periodEnd.getTime() < periodStart.getTime()) {
        parseFailure(`${field}.periodEnd must not precede ${field}.periodStart`);
      }
      return { periodStart, periodEnd };
    }

    function finiteNonnegativeCost(value, field) {
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
        parseFailure(`${field} must be a finite nonnegative number`);
      }
      if (value > Number.MAX_SAFE_INTEGER) {
        parseFailure(`${field} exceeds the safe numeric range`);
      }
      return value;
    }

    const profile = object(await getJSON(`${root}/api/whoami-v2`, "identity"), "identity response");
    const username = requiredString(profile.name, "identity.name");
    const email = optionalString(profile.email, "identity.email");
    if (profile.isPro !== undefined && profile.isPro !== null && typeof profile.isPro !== "boolean") {
      parseFailure("identity.isPro must be a boolean");
    }
    const isPro = profile.isPro === true;
    const billing = object(await getJSON(`${root}/api/settings/billing/usage/live`, "billing"), "billing response");
    const inference = object(billing.inference, "inference");
    const jobs = object(billing.jobs, "jobs");
    const inferencePeriod = parsePeriod(inference, "inference");
    const jobsPeriod = parsePeriod(jobs, "jobs");
    const inferenceNanoUSD = finiteNonnegativeCost(inference.usedNanoUsd, "inference.usedNanoUsd");
    const jobsMicroUSD = finiteNonnegativeCost(jobs.usedMicroUsd, "jobs.usedMicroUsd");
    const inferenceUSD = inferenceNanoUSD / 1_000_000_000;
    const jobsUSD = jobsMicroUSD / 1_000_000;
    if (!Number.isFinite(inferenceUSD) || !Number.isFinite(jobsUSD)) {
      parseFailure("billing cost total overflowed");
    }

    const plan = isPro ? "PRO" : "Free";
    const inferenceStartLabel = inferencePeriod.periodStart.toISOString().slice(0, 10);
    const inferenceEndLabel = inferencePeriod.periodEnd.toISOString().slice(0, 10);
    const jobsStartLabel = jobsPeriod.periodStart.toISOString().slice(0, 10);
    const jobsEndLabel = jobsPeriod.periodEnd.toISOString().slice(0, 10);
    return {
      cost: {
        used: inferenceUSD,
        currency: "USD",
        period: "Inference billing period",
        resetsAt: inferencePeriod.periodEnd,
      },
      identity: {
        email: email || undefined,
        accountID: username,
        loginMethod: plan,
      },
      dataConfidence: "exact",
      details: [
        {
          title: "Billing summary",
          rows: [
            { label: "Inference period", value: `${inferenceStartLabel} – ${inferenceEndLabel}` },
            { label: "Inference spend", value: ctx.format.usd(inferenceUSD) },
            { label: "Plan", value: plan },
          ],
        },
        {
          title: "Jobs billing",
          rows: [
            { label: "Jobs period", value: `${jobsStartLabel} – ${jobsEndLabel}` },
            { label: "Jobs spend", value: ctx.format.usd(jobsUSD) },
          ],
        },
      ],
    };
  },
});
