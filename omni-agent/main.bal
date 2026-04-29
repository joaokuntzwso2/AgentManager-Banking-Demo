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

function agentUrl(string envName, string fallback) returns string {
    string value = os:getEnv(envName);
    return value == "" ? fallback : value;
}

listener http:Listener agentListener = new(getPort());

type ChatRequest record {|
    string message;
    string customerId?;
    string sessionId?;
    map<json> context?;
|};

type AgentResult record {|
    string agent;
    string summary;
    string decision?;
    float riskScore;
    float confidence;
    string[] citations?;
|};

type ChatResponse record {|
    string agent;
    string answer;
    string decision?;
    float riskScore?;
    float confidence?;
    string[] citations?;
|};

type DownstreamResponse record {
    string agent;
    string answer;
    string decision?;
    float riskScore?;
    float confidence?;
    string[] citations?;
};

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

function shouldRouteToKyc(string msg) returns boolean {
    string m = msg.toLowerAscii();
    return m.includes("kyc") || m.includes("onboard") || m.includes("identity") ||
        m.includes("sanction") || m.includes("pep") || m.includes("jurisdiction") ||
        m.includes("beneficial owner") || m.includes("aml") || m.includes("high risk country");
}

function shouldRouteToFraud(string msg) returns boolean {
    string m = msg.toLowerAscii();
    return m.includes("fraud") || m.includes("chargeback") || m.includes("new device") ||
        m.includes("large transfer") || m.includes("failed login") ||
        m.includes("unusual location") || m.includes("beneficiary") ||
        m.includes("velocity") || m.includes("transfer");
}

function shouldRouteToPolicy(string msg) returns boolean {
    string m = msg.toLowerAscii();
    return m.includes("policy") || m.includes("limit") || m.includes("loan") ||
        m.includes("manual review") || m.includes("authentication") ||
        m.includes("regulation") || m.includes("affordability") ||
        m.includes("complaint") || m.includes("clarification");
}

function callAgent(string baseUrl, ChatRequest req) returns AgentResult|error {
    http:Client agentClient = check new(baseUrl);
    DownstreamResponse resp = check agentClient->post("/chat", req);

    return {
        agent: resp.agent,
        summary: resp.answer,
        decision: resp.decision ?: "NO_DECISION",
        riskScore: resp.riskScore ?: 0.0,
        confidence: resp.confidence ?: 0.70,
        citations: resp.citations ?: []
    };
}

function summarizeResults(ChatRequest req, AgentResult[] results) returns string|error {
    string joined = "";

    foreach AgentResult r in results {
        joined += "\nAGENT: " + r.agent;
        joined += "\nDECISION: " + (r.decision ?: "NO_DECISION");
        joined += "\nRISK SCORE: " + r.riskScore.toString();
        joined += "\nCONFIDENCE: " + r.confidence.toString();
        joined += "\nSUMMARY:\n" + r.summary + "\n";
    }

    string systemPrompt = string `
You are the Omni banking AI agent.

You receive outputs from specialist banking agents, but you must return ONE single consolidated response to the caller.

Rules:
- Do not expose raw downstream agent payloads.
- Do not say "the KYC agent said" unless useful for a concise finding.
- Merge findings into one coherent operational banking answer.
- Resolve conflicts.
- Identify missing data.
- Provide one final recommendation.
- Do not invent facts.
- Use a professional banking operations tone.

Final output sections:
1. Executive summary
2. Consolidated risk assessment
3. Recommended action
4. Missing information
5. Final decision
`;

    string userPrompt = string `
Original user request:
${req.message}

Specialist agent outputs:
${joined}
`;

    return callOpenAI(systemPrompt, userPrompt);
}

service / on agentListener {
    resource function get health() returns json {
        return {
            status: "UP",
            agent: "omni-agent",
            mode: "openai-orchestrator-single-response",
            kycAgentUrl: agentUrl("KYC_AGENT_URL", "http://localhost:8001"),
            fraudAgentUrl: agentUrl("FRAUD_AGENT_URL", "http://localhost:8002"),
            policyRagAgentUrl: agentUrl("POLICY_RAG_AGENT_URL", "http://localhost:8003")
        };
    }

    resource function post chat(@http:Payload ChatRequest req) returns ChatResponse {
        AgentResult[] results = [];
        string[] errors = [];

        if shouldRouteToKyc(req.message) {
            AgentResult|error r = callAgent(agentUrl("KYC_AGENT_URL", "http://localhost:8001"), req);
            if r is AgentResult {
                results.push(r);
            } else {
                errors.push("KYC unavailable: " + r.message());
            }
        }

        if shouldRouteToFraud(req.message) {
            AgentResult|error r = callAgent(agentUrl("FRAUD_AGENT_URL", "http://localhost:8002"), req);
            if r is AgentResult {
                results.push(r);
            } else {
                errors.push("Fraud unavailable: " + r.message());
            }
        }

        if shouldRouteToPolicy(req.message) || results.length() == 0 {
            AgentResult|error r = callAgent(agentUrl("POLICY_RAG_AGENT_URL", "http://localhost:8003"), req);
            if r is AgentResult {
                results.push(r);
            } else {
                errors.push("Policy RAG unavailable: " + r.message());
            }
        }

        if results.length() == 0 {
            return {
                agent: "omni-agent",
                answer: "No downstream banking agents were available. Errors: " + errors.toString(),
                decision: "RETRY",
                riskScore: 1.0,
                confidence: 0.0
            };
        }

        float maxRisk = 0.0;
        foreach AgentResult r in results {
            if r.riskScore > maxRisk {
                maxRisk = r.riskScore;
            }
        }

        string|error finalAnswer = summarizeResults(req, results);

        if finalAnswer is error {
            return {
                agent: "omni-agent",
                answer: "Specialist agents completed, but final OpenAI synthesis failed: " + finalAnswer.message(),
                decision: "PARTIAL_RESULT",
                riskScore: maxRisk,
                confidence: 0.50
            };
        }

        return {
            agent: "omni-agent",
            answer: finalAnswer,
            decision: "OMNI_REVIEW_COMPLETED",
            riskScore: maxRisk,
            confidence: 0.90
        };
    }
}
