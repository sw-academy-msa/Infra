"""Kafka EC2가 stopped가 되면 다시 시작합니다.

EventBridge의 EC2 상태 변경 이벤트로 호출됩니다. 이벤트를 그대로 믿지 않고 현재 상태와 태그를 다시 확인한 뒤,
여전히 stopped이고 유지보수 제외 태그(AutoRestart=false)가 없을 때만 StartInstances를 부릅니다.
terminated, EBS 손상, Kafka 프로세스 무응답, 설정 오류, 디스크 부족은 이 함수가 해결하지 않습니다.
"""

import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SKIP_TAG = "AutoRestart"


def _client():
    import boto3  # Lambda 런타임에 포함되어 있습니다. 테스트는 가짜 클라이언트를 넘깁니다.

    return boto3.client("ec2")


def decide(instance, target_id):
    """현재 인스턴스 정보로 무엇을 할지 정합니다. (동작, 이유)를 돌려줍니다."""
    if instance is None:
        return "skip", "instance-not-found"
    if instance.get("InstanceId") != target_id:
        return "skip", "not-target"
    tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
    if tags.get(SKIP_TAG, "").lower() == "false":
        return "skip", "maintenance"
    state = instance.get("State", {}).get("Name")
    if state != "stopped":
        # 이미 시작 중이거나 실행 중이면 아무것도 하지 않습니다(같은 이벤트가 두 번 와도 안전).
        return "skip", "state-" + str(state)
    return "start", "stopped"


def handler(event, context, ec2=None):
    target_id = os.environ["KAFKA_INSTANCE_ID"]
    event_id = (event.get("detail") or {}).get("instance-id")
    if event_id != target_id:
        logger.info(json.dumps({"action": "skip", "reason": "event-for-other-instance"}))
        return {"action": "skip", "reason": "event-for-other-instance"}

    ec2 = ec2 or _client()
    reservations = ec2.describe_instances(InstanceIds=[target_id]).get("Reservations", [])
    instances = [i for r in reservations for i in r.get("Instances", [])]
    action, reason = decide(instances[0] if instances else None, target_id)
    if action == "start":
        ec2.start_instances(InstanceIds=[target_id])
    logger.info(json.dumps({"action": action, "reason": reason, "instance": target_id}))
    return {"action": action, "reason": reason}
