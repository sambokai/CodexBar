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

    function encodedPathSegment(value) {
      // Encode dots too so a user name can never be interpreted as a relative path segment.
      return encodeURIComponent(value).replace(/\./g, "%2E");
    }

    function parsePeriod(period) {
      const value = object(period, "period");
      const periodStartText = requiredString(value.periodStart, "period.periodStart");
      const periodEndText = requiredString(value.periodEnd, "period.periodEnd");
      let periodStart;
      let periodEnd;
      try {
        periodStart = ctx.date.iso(periodStartText);
        periodEnd = ctx.date.iso(periodEndText);
      } catch {
        parseFailure("periodStart and periodEnd must be valid ISO-8601 dates");
      }
      if (periodEnd.getTime() < periodStart.getTime()) {
        parseFailure("periodEnd must not precede periodStart");
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

    function categoryLabel(value) {
      const words = value.replace(/[_-]+/g, " ").trim().split(/\s+/).filter(Boolean);
      return words.map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(" ");
    }

    const profile = object(await getJSON(`${root}/api/whoami-v2`, "identity"), "identity response");
    const username = requiredString(profile.name, "identity.name");
    const email = optionalString(profile.email, "identity.email");
    if (profile.isPro !== undefined && profile.isPro !== null && typeof profile.isPro !== "boolean") {
      parseFailure("identity.isPro must be a boolean");
    }
    const isPro = profile.isPro === true;
    const billing = object(
      await getJSON(`${root}/api/users/${encodedPathSegment(username)}/billing/usage/live`, "billing"),
      "billing response",
    );
    const period = parsePeriod(billing.period);
    const usage = object(billing.usage, "usage");
    const categories = [];
    let totalMicroUSD = 0;

    for (const category of Object.keys(usage)) {
      if (!category.trim() || !Array.isArray(usage[category])) {
        parseFailure(`usage.${category} must be an array`);
      }
      let categoryMicroUSD = 0;
      for (const [index, line] of usage[category].entries()) {
        object(line, `usage.${category}[${index}]`);
        const cost = finiteNonnegativeCost(line.totalCostMicroUSD, `usage.${category}[${index}].totalCostMicroUSD`);
        categoryMicroUSD += cost;
        if (!Number.isFinite(categoryMicroUSD)) {
          parseFailure(`usage.${category} cost total overflowed`);
        }
        totalMicroUSD += cost;
        if (!Number.isFinite(totalMicroUSD)) {
          parseFailure("usage cost total overflowed");
        }
      }
      categories.push({ key: category, label: categoryLabel(category), costMicroUSD: categoryMicroUSD });
    }

    const totalUSD = totalMicroUSD / 1_000_000;
    if (!Number.isFinite(totalUSD)) parseFailure("usage cost total overflowed");
    categories.sort((left, right) => {
      if (right.costMicroUSD !== left.costMicroUSD) return right.costMicroUSD - left.costMicroUSD;
      return left.label.localeCompare(right.label) || left.key.localeCompare(right.key);
    });

    const plan = isPro ? "PRO" : "Free";
    const startLabel = period.periodStart.toISOString().slice(0, 10);
    const endLabel = period.periodEnd.toISOString().slice(0, 10);
    return {
      cost: {
        used: totalUSD,
        currency: "USD",
        period: "Current billing period",
        resetsAt: period.periodEnd,
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
            { label: "Current period", value: `${startLabel} – ${endLabel}` },
            { label: "Current spend", value: ctx.format.usd(totalUSD) },
            { label: "Plan", value: plan },
          ],
        },
        {
          title: "Usage breakdown",
          rows: categories.map((category) => ({
            label: category.label,
            value: ctx.format.usd(category.costMicroUSD / 1_000_000),
          })),
        },
      ],
    };
  },
});
