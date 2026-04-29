FROM ballerina/ballerina:2201.12.9 AS build
USER root
WORKDIR /app
COPY . .
RUN bal build

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/bin/*.jar /app/agent.jar
ENV PORT=8000
EXPOSE 8000
ENTRYPOINT ["java", "-jar", "/app/agent.jar"]
