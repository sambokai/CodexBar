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

    async function getOptionalJSON(url) {
      try {
        const response = await ctx.http.get(url);
        if (typeof response.status !== "number" || response.status < 200 || response.status >= 300) return null;
        return JSON.parse(response.bodyText);
      } catch {
        return null;
      }
    }

    function parsePeriod(period) {
      const value = object(period, "billing.period");
      const periodStartText = requiredString(value.periodStart, "billing.period.periodStart");
      const periodEndText = requiredString(value.periodEnd, "billing.period.periodEnd");
      let periodStart;
      let periodEnd;
      try {
        periodStart = ctx.date.iso(periodStartText);
        periodEnd = ctx.date.iso(periodEndText);
      } catch {
        parseFailure("billing.period.periodStart and billing.period.periodEnd must be valid ISO-8601 dates");
      }
      if (periodEnd.getTime() < periodStart.getTime()) {
        parseFailure("billing.period.periodEnd must not precede billing.period.periodStart");
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

    function addCosts(total, cost, field) {
      const next = total + cost;
      if (!Number.isFinite(next) || next > Number.MAX_SAFE_INTEGER) {
        parseFailure(`${field} total exceeds the safe numeric range`);
      }
      return next;
    }

    function categoryLabel(value) {
      const normalized = value
        .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
        .replace(/[_-]+/g, " ")
        .trim();
      if (!normalized) return "Unknown";
      return normalized.replace(/\b\w/g, (character) => character.toUpperCase());
    }

    function compareRows(a, b) {
      if (a.costMicroUSD !== b.costMicroUSD) return b.costMicroUSD - a.costMicroUSD;
      if (a.label < b.label) return -1;
      if (a.label > b.label) return 1;
      return 0;
    }

    function unixSeconds(date) {
      const milliseconds = date.getTime();
      if (!Number.isFinite(milliseconds) || milliseconds % 1000 !== 0) return null;
      const seconds = milliseconds / 1000;
      return Number.isSafeInteger(seconds) ? seconds : null;
    }

    function safeNanoUSD(value) {
      if (
        typeof value !== "number" ||
        !Number.isFinite(value) ||
        !Number.isInteger(value) ||
        value < 0 ||
        !Number.isSafeInteger(value)
      ) {
        return null;
      }
      return value;
    }

    function parseInferenceUsageRemaining(response, period) {
      if (!response || typeof response !== "object" || Array.isArray(response)) return null;
      const usage = response.usage;
      if (!usage || typeof usage !== "object" || Array.isArray(usage)) return null;
      const inferenceProviders = usage.inferenceProviders;
      if (!inferenceProviders || typeof inferenceProviders !== "object" || Array.isArray(inferenceProviders)) {
        return null;
      }

      const usedNanoUSD = safeNanoUSD(inferenceProviders.usedNanoUsd);
      const includedNanoUSD = safeNanoUSD(inferenceProviders.includedNanoUsd);
      if (usedNanoUSD === null || includedNanoUSD === null) return null;

      if (
        typeof inferenceProviders.periodStart !== "string" ||
        !inferenceProviders.periodStart.trim() ||
        typeof inferenceProviders.periodEnd !== "string" ||
        !inferenceProviders.periodEnd.trim()
      ) {
        return null;
      }

      let inferencePeriodStart;
      let inferencePeriodEnd;
      try {
        inferencePeriodStart = ctx.date.iso(inferenceProviders.periodStart.trim());
        inferencePeriodEnd = ctx.date.iso(inferenceProviders.periodEnd.trim());
      } catch {
        return null;
      }

      const inferenceStartMilliseconds = inferencePeriodStart.getTime();
      const inferenceEndMilliseconds = inferencePeriodEnd.getTime();
      if (
        !Number.isFinite(inferenceStartMilliseconds) ||
        !Number.isFinite(inferenceEndMilliseconds) ||
        inferenceEndMilliseconds < inferenceStartMilliseconds ||
        inferenceStartMilliseconds !== period.periodStart.getTime() ||
        inferenceEndMilliseconds !== period.periodEnd.getTime()
      ) {
        return null;
      }

      const remainingNanoUSD = Math.max(0, includedNanoUSD - usedNanoUSD);
      return remainingNanoUSD / 1_000_000_000;
    }

    const profile = object(await getJSON(`${root}/api/whoami-v2`, "identity"), "identity response");
    const username = requiredString(profile.name, "identity.name");
    const email = optionalString(profile.email, "identity.email");
    if (profile.isPro !== undefined && profile.isPro !== null && typeof profile.isPro !== "boolean") {
      parseFailure("identity.isPro must be a boolean");
    }
    const isPro = profile.isPro === true;

    // This settings response is the selected finite billing source. Sum only the categories it returns;
    // do not infer whole-account coverage or credits from other Hugging Face billing routes.
    const billing = object(await getJSON(`${root}/api/settings/billing/usage`, "billing"), "billing response");
    const period = parsePeriod(billing.period);
    const usage = object(billing.usage, "billing.usage");
    const categoryRows = [];
    let totalMicroUSD = 0;
    for (const category of Object.keys(usage)) {
      const items = usage[category];
      if (!Array.isArray(items)) {
        parseFailure(`billing.usage.${category} must be an array`);
      }
      let categoryTotalMicroUSD = 0;
      for (let index = 0; index < items.length; index += 1) {
        const item = items[index];
        object(item, `billing.usage.${category}[${index}]`);
        const cost = finiteNonnegativeCost(
          item.totalCostMicroUSD,
          `billing.usage.${category}[${index}].totalCostMicroUSD`,
        );
        categoryTotalMicroUSD = addCosts(categoryTotalMicroUSD, cost, `billing.usage.${category}`);
      }
      totalMicroUSD = addCosts(totalMicroUSD, categoryTotalMicroUSD, "billing.usage");
      categoryRows.push({
        label: categoryLabel(category),
        costMicroUSD: categoryTotalMicroUSD,
      });
    }

    const totalUSD = totalMicroUSD / 1_000_000;
    if (!Number.isFinite(totalUSD)) parseFailure("billing cost total overflowed");
    categoryRows.sort(compareRows);

    const periodStartLabel = period.periodStart.toISOString().slice(0, 10);
    const periodEndLabel = period.periodEnd.toISOString().slice(0, 10);
    const isPersonalFree = profile.type === "user" && profile.isPro === false;
    let inferenceUsageRemaining = null;
    if (isPersonalFree) {
      const startDate = unixSeconds(period.periodStart);
      const endDate = unixSeconds(period.periodEnd);
      if (startDate !== null && endDate !== null) {
        const usageV2 = await getOptionalJSON(
          `${root}/api/settings/billing/usage-v2?startDate=${startDate}&endDate=${endDate}`,
        );
        inferenceUsageRemaining = parseInferenceUsageRemaining(usageV2, period);
      }
    }
    const identity = {
      email: email || undefined,
      accountID: username,
    };
    if (isPro) identity.loginMethod = "PRO";

    return {
      cost: {
        used: totalUSD,
        currency: "USD",
        period: "Reported billing period",
        resetsAt: period.periodEnd,
      },
      identity,
      dataConfidence: "exact",
      details: [
        {
          title: "Billing summary",
          rows: [
            { label: "Billing period", value: `${periodStartLabel} – ${periodEndLabel}` },
            { label: "Reported spend", value: ctx.format.usd(totalUSD) },
            ...(inferenceUsageRemaining !== null
              ? [{ label: "Inference usage remaining", value: ctx.format.usd(inferenceUsageRemaining) }]
              : []),
            ...(isPro ? [{ label: "Plan", value: "PRO" }] : []),
          ],
        },
        {
          title: "Usage breakdown",
          rows: categoryRows.map((row) => ({
            label: row.label,
            value: ctx.format.usd(row.costMicroUSD / 1_000_000),
          })),
        },
      ],
    };
  },
});
