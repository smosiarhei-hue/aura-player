export default {
  async fetch(request, env) {
    const headers = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Authorization, Content-Type",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Content-Type": "application/json; charset=utf-8",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers });
    }

    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return Response.json({
        status: "ok",
        service: "sonivo-ai",
        model: env.GEMINI_MODEL || "gemini-2.5-flash",
      }, { headers });
    }

    if (request.method !== "POST" || url.pathname !== "/rank") {
      return Response.json({ error: "Not found" }, { status: 404, headers });
    }

    const expectedAuthorization = "Bearer " + (env.APP_TOKEN || "");
    if (!env.APP_TOKEN || request.headers.get("Authorization") !== expectedAuthorization) {
      return Response.json({ error: "Unauthorized" }, { status: 401, headers });
    }

    let input;
    try {
      input = await request.json();
    } catch {
      return Response.json({ error: "Invalid JSON" }, { status: 400, headers });
    }

    const candidates = Array.isArray(input.candidates) ? input.candidates.slice(0, 60) : [];
    if (candidates.length === 0) {
      return Response.json({ error: "Candidates are required" }, { status: 400, headers });
    }
    if (!env.GEMINI_API_KEY) {
      return Response.json({ error: "GEMINI_API_KEY is not configured" }, { status: 500, headers });
    }

    const intent = typeof input.intent === "string"
      ? input.intent.slice(0, 300)
      : "Продолжить текущую песню максимально похожими треками";
    const seed = input.seed || {};
    const allowedIds = new Set(candidates.map((candidate) => String(candidate.id)));

    const prompt = [
      "Ты — музыкальный рекомендательный ранжировщик приложения Sonivo.",
      "Расположи только предоставленные треки по релевантности.",
      "Учитывай текущую песню, запрос, настроение, жанровую, эмоциональную и темповую совместимость.",
      "Не придумывай ID. Избегай однообразия и большого количества песен одного исполнителя подряд.",
      "Первые песни должны быть наиболее естественным продолжением текущей.",
      "Запрос пользователя: " + intent,
      "Текущая песня: " + JSON.stringify(seed),
      "Доступные кандидаты: " + JSON.stringify(candidates),
    ].join("\n\n");

    const model = env.GEMINI_MODEL || "gemini-2.5-flash";
    const geminiOrigin = "https:" + "/" + "/" + "generativelanguage.googleapis.com";
    const geminiURL = geminiOrigin + "/v1beta/models/" + encodeURIComponent(model) +
      ":generateContent?key=" + encodeURIComponent(env.GEMINI_API_KEY);

    const geminiResponse = await fetch(geminiURL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: prompt }] }],
        generationConfig: {
          temperature: 0.2,
          maxOutputTokens: 2048,
          responseMimeType: "application/json",
          responseSchema: {
            type: "OBJECT",
            properties: {
              category: { type: "STRING" },
              ordered_ids: { type: "ARRAY", items: { type: "STRING" } },
              explanation: { type: "STRING" },
            },
            required: ["category", "ordered_ids"],
          },
        },
      }),
    });

    if (!geminiResponse.ok) {
      const details = await geminiResponse.text();
      return Response.json({
        error: "Gemini request failed",
        status: geminiResponse.status,
        details: details.slice(0, 500),
      }, { status: 502, headers });
    }

    const geminiData = await geminiResponse.json();
    const responseText = geminiData?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!responseText) {
      return Response.json({ error: "Gemini returned an empty response" }, { status: 502, headers });
    }

    let ranking;
    try {
      ranking = JSON.parse(responseText);
    } catch {
      return Response.json({ error: "Gemini returned invalid JSON" }, { status: 502, headers });
    }

    const orderedIds = Array.isArray(ranking.ordered_ids)
      ? ranking.ordered_ids
          .map(String)
          .filter((id, index, values) => allowedIds.has(id) && values.indexOf(id) === index)
      : [];

    return Response.json({
      category: ranking.category || "ИИ-волна",
      ordered_ids: orderedIds,
      explanation: ranking.explanation || "",
    }, { headers });
  },
};
