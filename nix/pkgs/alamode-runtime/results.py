def classify_result(events, exit_code=0, *, aborted=False, timed_out=False):
    """Classify one alamode turn. Verification is a separate trusted outcome."""
    final = None
    settled = False
    for event in events:
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if kind == "agent_start":
            final = None
            settled = False
        elif kind == "message_end":
            message = event.get("message", {})
            if isinstance(message, dict) and message.get("role") == "assistant":
                final = message
                settled = False
        elif kind == "agent_end" and final is None:
            for message in event.get("messages") or []:
                if isinstance(message, dict) and message.get("role") == "assistant":
                    final = message
        elif kind == "agent_settled":
            settled = True

    final = final or {}
    content = final.get("content")
    text = "\n".join(
        block["text"]
        for block in (content if isinstance(content, list) else [])
        if isinstance(block, dict)
        and block.get("type") == "text"
        and isinstance(block.get("text"), str)
    ).strip()[:1048576]
    reason = final.get("stopReason")
    if timed_out:
        state, error = "timeout", "Agent timed out"
    elif aborted or reason == "aborted":
        state, error = "aborted", "Agent was cancelled"
    elif exit_code != 0:
        state, error = "error", f"Agent process exited with code {exit_code}"
    elif reason == "error":
        state, error = "error", final.get("errorMessage") or "Provider request failed"
    elif not settled or reason != "stop":
        state, error = (
            "incomplete",
            "Agent did not settle with a completed assistant reply",
        )
    elif not text:
        state, error = "empty", "Agent returned an empty assistant reply"
    else:
        state, error = "success", None
    return {"state": state, "text": text, "error": error}
