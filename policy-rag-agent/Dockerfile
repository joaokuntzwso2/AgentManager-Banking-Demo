FROM ballerina/ballerina:2201.12.9 AS build
USER root
WORKDIR /app
COPY . .
RUN bal build

FROM eclipse-temurin:21-jre

RUN groupadd -r appgroup && useradd -r -g appgroup -d /app -s /sbin/nologin appuser

WORKDIR /app
COPY --from=build /app/target/bin/*.jar /app/agent.jar

RUN chown -R appuser:appgroup /app

ENV PORT=8000
EXPOSE 8000

USER appuser

ENTRYPOINT ["java", "-jar", "/app/agent.jar"]