"""End-to-end tests: HTTP -> API Gateway -> Lambda -> DynamoDB (on AWS Emulator)."""

TARGET = "https://github.com/aws/aws-emulator"


def test_create_link_returns_code(api):
    res = api.request("POST", "/links", json={"url": TARGET})
    assert res.status_code == 201, res.text
    body = res.json()
    assert body["url"] == TARGET
    assert len(body["code"]) == 7


def test_link_is_persisted_in_dynamodb(api, table):
    code = api.request("POST", "/links", json={"url": TARGET}).json()["code"]
    item = table.get_item(Key={"code": code}).get("Item")
    assert item is not None
    assert item["url"] == TARGET
    assert int(item["hits"]) == 0


def test_redirect_and_hit_counter(api):
    code = api.request("POST", "/links", json={"url": TARGET}).json()["code"]

    first = api.request("GET", f"/links/{code}")
    second = api.request("GET", f"/links/{code}")

    assert first.status_code == 301, first.text
    assert first.headers["Location"] == TARGET
    assert first.json()["hits"] == 1
    assert second.json()["hits"] == 2


def test_invalid_url_is_rejected(api):
    res = api.request("POST", "/links", json={"url": "javascript:alert(1)"})
    assert res.status_code == 400


def test_unknown_code_returns_404(api):
    res = api.request("GET", "/links/doesnotexist")
    assert res.status_code == 404
