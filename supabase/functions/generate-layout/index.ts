// supabase/functions/generate-layout/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");

serve(async (req: Request): Promise<Response> => {
  // Preflight CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers":
          "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  try {
    if (!OPENAI_API_KEY) throw new Error("Missing OPENAI_API_KEY");

    const { prompt, deviceMode, currentLayout } = await req.json();

    // --- CALL OPENAI RESPONSES API ---
    const aiRes = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: "gpt-4.1-mini",
        input: [
          {
            role: "system",
            content: `
Eres un motor generador de layouts JSON para un builder no-code.

Devuelves SIEMPRE un JSON PURO con esta forma:

{
  "type": "page",
  "id": "root",
  "device": "desktop" | "mobile",
  "children": [...]
}

Nodos válidos: page, section, heading, text, button.
NO uses markdown. NO expliques nada. NO incluyas texto fuera del JSON.
`.trim(),
          },
          {
            role: "user",
            content: {
              prompt,
              deviceMode,
              currentLayout: currentLayout || null,
            },
          },
        ],
        response_format: { type: "json_object" },
      }),
    });

    const data = await aiRes.json();

    // --- READ JSON FROM RESPONSES API (Formato GPT-4.1) ---
    let rawJSON = "";

    if (data.output?.[0]?.content?.[0]?.text) {
      rawJSON = data.output[0].content[0].text;
    } else if (data?.choices?.[0]?.message?.content) {
      rawJSON = data.choices[0].message.content;
    }

    let layout: any = null;

    try {
      layout = JSON.parse(rawJSON);
    } catch {
      layout = null;
    }

    // Fallback si la IA falla
    if (!layout || layout.type !== "page") {
      layout = {
        type: "page",
        id: "root",
        device: deviceMode,
        children: [
          {
            type: "section",
            id: "hero",
            props: {
              padding: 32,
              background: "#ffffff",
            },
            children: [
              {
                type: "heading",
                id: "title",
                props: {
                  text: "Nuevo layout desde IA",
                  level: 1,
                  align: "center",
                },
              },
              {
                type: "text",
                id: "subtitle",
                props: {
                  text: `Prompt: ${prompt}`,
                  align: "center",
                },
              },
            ],
          },
        ],
      };
    }

    return new Response(JSON.stringify({ success: true, layout }), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (err: unknown) {
    console.error(err);

    return new Response(
      JSON.stringify({
        success: false,
        error: err instanceof Error ? err.message : "Unknown error",
      }),
      {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      },
    );
  }
});
