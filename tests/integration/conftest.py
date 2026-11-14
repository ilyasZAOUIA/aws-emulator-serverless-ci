"""Shared fixtures: read Terraform outputs and build an API client.

AWS Emulator serves every API Gateway API on one endpoint. The target API is
picked by the Host header (<api_id>.execute-api.<region>.amazonaws.com) and
the stage name goes first in the path.
"""
import json
import os
import subprocess
from pathlib import Path

import boto3
import pytest
import requests

INFRA_DIR = Path(__file__).resolve().parents[2] / "infra"


@pytest.fixture(scope="session")
def tf_outputs():
    raw = subprocess.run(
        ["terraform", f"-chdir={INFRA_DIR}", "output", "-json"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return {k: v["value"] for k, v in json.loads(raw).items()}


class ApiClient:
    def __init__(self, outputs):
        self.base = os.environ["AWS_ENDPOINT_URL"].rstrip("/")
        self.stage = outputs["stage_name"]
        region = os.environ.get("AWS_REGION", "us-east-1")
        self.host = f"{outputs['api_id']}.execute-api.{region}.amazonaws.com"
        self.verify = os.environ.get("AWS_CA_BUNDLE", True)

    def request(self, method, path, **kwargs):
        return requests.request(
            method,
            f"{self.base}/{self.stage}{path}",
            headers={"Host": self.host},
            verify=self.verify,
            allow_redirects=False,
            timeout=30,
            **kwargs,
        )


@pytest.fixture(scope="session")
def api(tf_outputs):
    return ApiClient(tf_outputs)


@pytest.fixture(scope="session")
def table(tf_outputs):
    return boto3.resource("dynamodb").Table(tf_outputs["table_name"])
