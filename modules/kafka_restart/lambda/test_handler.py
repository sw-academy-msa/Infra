"""handler.py 단위 테스트입니다. AWS에 접속하지 않고 가짜 EC2 클라이언트로 확인합니다.

실행: python -m unittest discover -s modules/kafka_restart/lambda
"""

import os
import unittest

import handler

TARGET = "i-0kafka"


class FakeEc2:
    def __init__(self, state="stopped", tags=None, found=True):
        self.instance = {"InstanceId": TARGET, "State": {"Name": state}, "Tags": tags or []}
        self.found = found
        self.started = []

    def describe_instances(self, InstanceIds):
        return {"Reservations": [{"Instances": [self.instance]}]} if self.found else {"Reservations": []}

    def start_instances(self, InstanceIds):
        self.started.extend(InstanceIds)


def event(instance_id=TARGET, state="stopped"):
    return {"detail": {"instance-id": instance_id, "state": state}}


class HandlerTest(unittest.TestCase):
    def setUp(self):
        os.environ["KAFKA_INSTANCE_ID"] = TARGET

    def test_starts_stopped_kafka(self):
        ec2 = FakeEc2()
        self.assertEqual(handler.handler(event(), None, ec2)["action"], "start")
        self.assertEqual(ec2.started, [TARGET])

    def test_skips_maintenance_tag(self):
        ec2 = FakeEc2(tags=[{"Key": "AutoRestart", "Value": "false"}])
        self.assertEqual(handler.handler(event(), None, ec2)["reason"], "maintenance")
        self.assertEqual(ec2.started, [])

    def test_skips_when_already_running(self):
        # 같은 이벤트가 다시 오거나 사람이 먼저 시작한 경우입니다.
        ec2 = FakeEc2(state="pending")
        self.assertEqual(handler.handler(event(), None, ec2)["action"], "skip")
        self.assertEqual(ec2.started, [])

    def test_skips_other_instance_event_without_api_call(self):
        ec2 = FakeEc2()
        self.assertEqual(handler.handler(event("i-other"), None, ec2)["reason"], "event-for-other-instance")
        self.assertEqual(ec2.started, [])

    def test_skips_terminated_or_missing(self):
        self.assertEqual(handler.handler(event(), None, FakeEc2(state="terminated"))["action"], "skip")
        self.assertEqual(handler.handler(event(), None, FakeEc2(found=False))["reason"], "instance-not-found")


if __name__ == "__main__":
    unittest.main()
