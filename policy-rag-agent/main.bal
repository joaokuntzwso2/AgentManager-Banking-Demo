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

type PolicyDoc record {|
    string id;
    string title;
    string content;
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

final PolicyDoc[] POLICY_DOCS = [
    {
        id: "POL-001",
        title: "Retail Payment Limits",
        content: "Retail customers may execute instant payments up to 5000 per transaction. Transactions above 5000 require step-up authentication. Transactions above 25000 require manual review before release."
    },
    {
        id: "POL-002",
        title: "Loan Affordability",
        content: "Loan recommendations must consider verified income, employment stability, existing debt, credit history, debt-to-income ratio, affordability buffers, and regulatory suitability."
    },
    {
        id: "POL-003",
        title: "KYC Enhanced Due Diligence",
        content: "Enhanced due diligence is required for politically exposed persons, sanctioned entities, customers from high-risk jurisdictions, complex ownership structures, shell companies, and adverse media."
    },
    {
        id: "POL-004",
        title: "Digital Fraud Controls",
        content: "High-risk events include new device enrollment, unusual geolocation, transaction velocity spikes, repeated failed authentication, beneficiary changes, remote access indicators, and high-value transfers."
    },
    {
        id: "POL-005",
        title: "Complaint Handling",
        content: "Customer complaints must be acknowledged promptly, categorized by severity, routed to the accountable operations team, and resolved within applicable regulatory service-level agreements."
    }
];

function score(string query, PolicyDoc doc) returns int {
    string q = query.toLowerAscii();
    string text = (doc.title + " " + doc.content).toLowerAscii();
    int s = 0;

    string[] terms = [
        "payment", "limit", "loan", "affordability", "kyc", "pep", "sanction",
        "fraud", "device", "transfer", "manual", "review", "authentication",
        "jurisdiction", "complaint", "beneficiary", "income", "debt"
    ];

    foreach string term in terms {
        if q.includes(term) && text.includes(term) {
            s += 1;
        }
    }

    return s;
}

function retrieveContext(string query) returns string {
    string context = "";
    int hits = 0;

    foreach PolicyDoc doc in POLICY_DOCS {
        if score(query, doc) > 0 {
            context += "[" + doc.id + "] " + doc.title + ": " + doc.content + "\n";
            hits += 1;
        }
    }

    if hits == 0 {
        foreach PolicyDoc doc in POLICY_DOCS {
            context += "[" + doc.id + "] " + doc.title + ": " + doc.content + "\n";
        }
    }

    return context;
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
        return {status: "UP", agent: "policy-rag-agent", mode: "openai-rag"};
    }

    resource function post chat(@http:Payload ChatRequest req) returns ChatResponse {
        string retrievedContext = retrieveContext(req.message);

        string systemPrompt = string `
You are the banking policy RAG agent.

Use only the provided policy context.
If the policy context does not contain the answer, say that the policy corpus does not contain enough information.
Do not invent policy clauses.
Cite policy IDs explicitly.
Return a clear operational answer for banking staff.
`;

        string userPrompt = string `
Retrieved policy context:
${retrievedContext}

Customer ID: ${req.customerId ?: "unknown"}
Session ID: ${req.sessionId ?: "unknown"}

Question:
${req.message}
`;

        string|error result = callOpenAI(systemPrompt, userPrompt);

        if result is error {
            return {
                agent: "policy-rag-agent",
                answer: "Policy RAG agent failed to call OpenAI: " + result.message(),
                decision: "ERROR",
                riskScore: 1.0,
                confidence: 0.0
            };
        }

        return {
            agent: "policy-rag-agent",
            answer: result,
            decision: "POLICY_RAG_COMPLETED",
            riskScore: 0.20,
            confidence: 0.88,
            citations: ["In-memory banking policy corpus"]
        };
    }
}
