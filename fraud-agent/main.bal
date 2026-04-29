import ballerina/http;
import ballerina/os;

function getPort() returns int {
    string portValue = os:getEnv("PORT");
    if portValue == "" {
        portValue = "8000";
    }
    int|error p = int:fromString(portValue);
    return p is int ? p : 8000;
}

function getEnvOrDefault(string key, string fallback) returns string {
    string value = os:getEnv(key);
    return value == "" ? fallback : value;
}

listener http:Listener agentListener = new(getPort());

type ChatRequest record {|
    string message;
    string customerId?;
    string sessionId?;
    map<json> context?;
|};

type ChatResponse record {|
    string agent;
    string answer;
    string decision?;
    float riskScore?;
    float confidence?;
    string[] citations?;
|};

type OpenAIMessage record {
    string role;
    string content;
};

type OpenAIRequest record {
    string model;
    OpenAIMessage[] messages;
    decimal temperature;
};

type OpenAIChoice record {
    OpenAIMessage message;
};

type OpenAIResponse record {
    OpenAIChoice[] choices;
};

function callOpenAI(string systemPrompt, string userPrompt) returns string|error {
    string apiKey = os:getEnv("OPENAI_API_KEY");
    if apiKey == "" {
        return error("OPENAI_API_KEY is not set");
    }

    string model = getEnvOrDefault("OPENAI_MODEL", "gpt-4.1-mini");
    http:Client openAiClient = check new("https://api.openai.com");

    OpenAIRequest payload = {
        model,
        temperature: 0.1,
        messages: [
            {role: "system", content: systemPrompt},
            {role: "user", content: userPrompt}
        ]
    };

    map<string|string[]> headers = {
        "Authorization": "Bearer " + apiKey,
        "Content-Type": "application/json"
    };

    OpenAIResponse response = check openAiClient->post("/v1/chat/completions", payload, headers);

    if response.choices.length() == 0 {
        return error("OpenAI returned no choices");
    }

    return response.choices[0].message.content;
}

service / on agentListener {
    resource function get health() returns json {
        return {status: "UP", agent: "fraud-agent", mode: "openai"};
    }

    resource function post chat(@http:Payload ChatRequest req) returns ChatResponse {
        string systemPrompt = string `
You are the fraud detection specialist agent for a digital bank.

Your job:
- Analyze fraud signals in banking activity.
- Consider new device, unusual geolocation, payment velocity, beneficiary changes, failed login attempts, chargebacks, mule-account indicators, and high-value transfers.
- Recommend allow, step-up authentication, hold, block, or escalate.
- Do not invent unavailable transaction data.
- Ask for missing fields when necessary.

Always include:
1. Fraud signal summary
2. Risk indicators
3. Recommended action
4. Risk score from 0.0 to 1.0
5. Explanation suitable for fraud operations
`;

        string userPrompt = string `
Customer ID: ${req.customerId ?: "unknown"}
Session ID: ${req.sessionId ?: "unknown"}

Fraud case:
${req.message}
`;

        string|error result = callOpenAI(systemPrompt, userPrompt);

        if result is error {
            return {
                agent: "fraud-agent",
                answer: "Fraud agent failed to call OpenAI: " + result.message(),
                decision: "ERROR",
                riskScore: 1.0,
                confidence: 0.0
            };
        }

        return {
            agent: "fraud-agent",
            answer: result,
            decision: "FRAUD_REVIEW_COMPLETED",
            riskScore: 0.50,
            confidence: 0.85,
            citations: ["OpenAI-generated fraud analysis using bank fraud operations system prompt"]
        };
    }
}
