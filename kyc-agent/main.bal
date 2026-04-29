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

type ChatRequest record {
    string message;
    string session_id?;
    string customerId?;
    string sessionId?;
    map<json> context?;
};

type ChatResponse record {|
    string response;
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

function getSessionId(ChatRequest req) returns string {
    string? sid1 = req.session_id;
    if sid1 is string {
        return sid1;
    }

    string? sid2 = req.sessionId;
    if sid2 is string {
        return sid2;
    }

    return "unknown";
}

function getCustomerId(ChatRequest req) returns string {
    string? customerId = req.customerId;
    if customerId is string {
        return customerId;
    }

    if req.context is map<json> {
        json? customerIdValue = req.context["customerId"];
        if customerIdValue is string {
            return customerIdValue;
        }
    }

    return "unknown";
}

function callOpenAI(string systemPrompt, string userPrompt) returns string|error {
    string apiKey = os:getEnv("OPENAI_API_KEY");
    if apiKey == "" {
        return error("OPENAI_API_KEY is not set");
    }

    string model = getEnvOrDefault("OPENAI_MODEL", "gpt-4.1-mini");
    http:Client openAiClient = check new("https://api.openai.com");

    OpenAIRequest payload = {
        model,
        temperature: 0.2,
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

function handleKycChat(ChatRequest req) returns ChatResponse {
    string systemPrompt = string `
You are the KYC and AML specialist agent for a regulated bank.

Your job:
- Analyze customer onboarding, identity verification, sanctions, PEP exposure, adverse media, beneficial ownership, source of funds, source of wealth, and jurisdiction risk.
- Produce a practical compliance assessment.
- Do not invent facts.
- If data is missing, say what is missing.
- Return concise banking-grade output.

Always include:
1. KYC assessment
2. AML concerns
3. Missing information
4. Recommended decision
5. Risk score from 0.0 to 1.0
`;

    string userPrompt = string `
Customer ID: ${getCustomerId(req)}
Session ID: ${getSessionId(req)}

User request:
${req.message}
`;

    string|error result = callOpenAI(systemPrompt, userPrompt);

    if result is error {
        return {
            response: "KYC agent failed to call OpenAI: " + result.message()
        };
    }

    return {
        response: result
    };
}

service / on agentListener {
    resource function get health() returns json {
        return {status: "UP", agent: "kyc-agent", mode: "openai"};
    }

    resource function post chat(@http:Payload ChatRequest req) returns http:Ok {
        return {
            body: handleKycChat(req)
        };
    }

    resource function post 'default\-default\-kyc\-agent/chat(@http:Payload ChatRequest req) returns http:Ok {
        return {
            body: handleKycChat(req)
        };
    }

    resource function post 'kyc\-agent\-kyc\-agent\-endpoint/chat(@http:Payload ChatRequest req) returns http:Ok {
        return {
            body: handleKycChat(req)
        };
    }
}

service /'default\-default\-kyc\-agent on agentListener {
    resource function post chat(@http:Payload ChatRequest req) returns http:Ok {
        return {
            body: handleKycChat(req)
        };
    }
}

service /'kyc\-agent\-kyc\-agent\-endpoint on agentListener {
    resource function post chat(@http:Payload ChatRequest req) returns http:Ok {
        return {
            body: handleKycChat(req)
        };
    }
}