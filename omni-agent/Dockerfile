FROM ballerina/ballerina:2201.12.9 AS build
USER root
WORKDIR /app
COPY . .
RUN bal build

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/bin/*.jar /app/agent.jar
ENV PORT=8000
ENV KYC_AGENT_URL=http://kyc-agent:8000
ENV FRAUD_AGENT_URL=http://fraud-agent:8000
ENV POLICY_RAG_AGENT_URL=http://policy-rag-agent:8000
EXPOSE 8000
ENTRYPOINT ["java", "-jar", "/app/agent.jar"]
