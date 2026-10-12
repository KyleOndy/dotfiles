import json
from pathlib import Path
from results import classify_result


def test_results():
    cases = json.loads(Path(__file__).with_name("result-fixtures.json").read_text())
    for case in cases:
        result = classify_result(
            case["events"],
            case.get("exit_code", 0),
            aborted=case.get("aborted", False),
            timed_out=case.get("timed_out", False),
        )
        assert result["state"] == case["expected"]["state"], case["name"]
        assert result["text"] == case["expected"]["text"], case["name"]
    print(f"PASS: {len(cases)} execution result fixtures")


if __name__ == "__main__":
    test_results()
