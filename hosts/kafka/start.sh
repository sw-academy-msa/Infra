#!/bin/bash
# Kafka 브로커와 exporter를 띄우고 토픽을 준비합니다. 다시 실행해도 데이터와 기존 토픽은 바뀌지 않습니다.
set -euo pipefail
cd "$(dirname "$0")"
# 다른 EC2가 접속할 광고 주소입니다. EC2를 다시 만들어도 바뀌지 않는 내부 DNS 이름을 씁니다.
ADVERTISED="${KAFKA_ADVERTISED_HOST:-kafka.${INTERNAL_DOMAIN:-stockdrop.internal}}"

# JMX agent는 Monitoring 레포 Download-JmxExporter.ps1과 같은 버전·체크섬입니다. 체크섬이 다르면 멈춥니다.
JMX_VERSION=1.5.0
JMX_SHA256=0315f3f657876302c6205a98d4036ec775dca529c5d0419ca60ee669c688239f
JAR=jmx_prometheus_javaagent.jar
if ! echo "$JMX_SHA256  $JAR" | sha256sum -c --quiet 2>/dev/null; then
  curl -fsSL -o "$JAR.download" \
    "https://github.com/prometheus/jmx_exporter/releases/download/$JMX_VERSION/jmx_prometheus_javaagent-$JMX_VERSION.jar"
  echo "$JMX_SHA256  $JAR.download" | sha256sum -c --quiet
  mv "$JAR.download" "$JAR"
fi

# 컨테이너 사용자(uid 1000)가 데이터 디렉터리에 쓸 수 있게 합니다.
mkdir -p /data/kafka && chown 1000:1000 /data/kafka
KAFKA_ADVERTISED_HOST="$ADVERTISED" docker compose up -d --wait
bash topics.sh
