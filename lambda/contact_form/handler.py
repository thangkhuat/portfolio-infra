"""Contact form handler for thangkhuat.dev.

Reached only through a Lambda function URL that CloudFront signs with
SigV4 — the URL is AWS_IAM-authorized and its resource policy names one
distribution, so this code is never exposed directly to the internet.
See ADR-012.

Flow: parse -> validate -> persist to DynamoDB -> notify by SES.

Three things about the shape of this file are deliberate:

  * No third-party dependencies. boto3 ships in the Python runtime, so
    the deployment package is this one file zipped by Terraform's
    archive_file provider, and the repo keeps its no-build-step property.

  * The interesting logic lives in pure functions. _clean, _parse_request
    and _validate touch no AWS service, so the security behaviour that
    matters most is testable without stubbing anything.

  * Everything the stored record is trusted for — id, timestamp, source
    IP, user agent — is generated here. A submitter controls exactly four
    fields, and none of them is one we later rely on.
"""

import base64
import hashlib
import html
import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Built at import rather than per-request so the underlying connections
# survive warm invocations. Inside the handler they would be rebuilt on
# every call.
dynamodb = boto3.resource("dynamodb")
ses = boto3.client("ses")

# Read at import too, so a misconfigured function fails once at cold
# start rather than silently on every request. Tests set these before
# importing this module.
TABLE_NAME = os.environ["SUBMISSIONS_TABLE"]
FROM_ADDRESS = os.environ["SES_FROM_ADDRESS"]
TO_ADDRESS = os.environ["SES_TO_ADDRESS"]

table = dynamodb.Table(TABLE_NAME)

# The HTML maxlength attributes are a usability affordance; anyone can
# POST past them with curl, so these are the limits that actually hold.
MAX_BODY_BYTES = 16 * 1024
MAX_NAME = 100
MAX_EMAIL = 254  # RFC 5321 maximum forward-path length
MAX_MESSAGE = 5000

# Deliberately permissive. Strict RFC 5322 parsing rejects addresses real
# mail servers accept, and a bad address costs a bounce, not a security
# failure — so this asserts rough shape and nothing more.
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$")

TOPICS = {
    "collaboration": "Collaboration",
    "opportunity": "Job opportunity",
    "general": "General enquiry",
}

SUCCESS_MESSAGE = "Thanks — your message has been sent."
GENERIC_ERROR = "Something went wrong sending your message. Please email me directly instead."


def _response(status, payload):
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json",
            # No CORS headers, deliberately. The form is served from the
            # same origin as this endpoint, which also means a page on any
            # other origin cannot read the response even if it POSTs here.
            "cache-control": "no-store",
        },
        "body": json.dumps(payload),
    }


def _clean(value, limit):
    """Coerce one submitted field to a bounded, single-line string.

    Rejecting CR and LF is the important part, not the trimming. `name`
    and `email` end up in the SES Subject and Reply-To headers, and a
    newline inside a header value is the classic email header injection
    vector — it lets a submitter append their own `Bcc:` line and turn
    this form into a relay sending DKIM-signed mail from our domain.

    Returns None when the value cannot be used.
    """
    if not isinstance(value, str):
        return None
    if "\r" in value or "\n" in value:
        return None
    value = value.strip()
    if not value or len(value) > limit:
        return None
    return value


def _parse_request(event):
    """Return (payload, error_response). Exactly one of the two is None."""
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    if method != "POST":
        return None, _response(405, {"error": "Method not allowed."})

    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        try:
            raw = base64.b64decode(raw).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return None, _response(400, {"error": "Could not read that request."})

    # Checked before json.loads so an oversized body is rejected on length
    # rather than after the parser has already walked all of it.
    if len(raw.encode("utf-8")) > MAX_BODY_BYTES:
        return None, _response(413, {"error": "That message is too long."})

    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None, _response(400, {"error": "Could not read that request."})

    if not isinstance(payload, dict):
        return None, _response(400, {"error": "Could not read that request."})

    return payload, None


def _validate(payload):
    """Return (fields, error_response). Exactly one of the two is None."""
    name = _clean(payload.get("name"), MAX_NAME)
    if not name:
        return None, _response(400, {"error": "Please enter your name."})

    email = _clean(payload.get("email"), MAX_EMAIL)
    if not email or not EMAIL_PATTERN.match(email):
        return None, _response(400, {"error": "Please enter a valid email address."})

    # message is the one field allowed to contain newlines — it goes in
    # the email body, not a header — so it gets its own bounds check
    # rather than going through _clean().
    message = payload.get("message")
    if not isinstance(message, str):
        return None, _response(400, {"error": "Please enter a message."})
    message = message.strip()
    if not message:
        return None, _response(400, {"error": "Please enter a message."})
    if len(message) > MAX_MESSAGE:
        return None, _response(400, {"error": "That message is too long."})

    # An unrecognised topic falls back rather than failing. The <select>
    # offers a fixed list, so an unexpected value means a bot or a
    # hand-rolled POST — neither worth rejecting a genuine message over.
    topic = payload.get("topic")
    if topic not in TOPICS:
        topic = "general"

    return {"name": name, "email": email, "message": message, "topic": topic}, None


def _send_email(fields, submission_id, submitted_at):
    """Notify the site owner. Raises ClientError if SES rejects the send."""
    body = (
        f"{TOPICS[fields['topic']]} via thangkhuat.dev\n\n"
        f"From:    {fields['name']} <{fields['email']}>\n"
        f"Sent:    {submitted_at}\n"
        f"Ref:     {submission_id}\n\n"
        f"{'-' * 60}\n\n"
        f"{fields['message']}\n"
    )

    ses.send_email(
        Source=FROM_ADDRESS,
        Destination={"ToAddresses": [TO_ADDRESS]},
        # Replies go to the submitter rather than the unmonitored noreply
        # sender. Safe to build from user input only because _clean() has
        # already rejected any value containing CR or LF.
        ReplyToAddresses=[fields["email"]],
        Message={
            "Subject": {
                "Data": f"[{TOPICS[fields['topic']]}] {fields['name']} via thangkhuat.dev",
                "Charset": "UTF-8",
            },
            "Body": {
                "Text": {"Data": body, "Charset": "UTF-8"},
                # Escaped because this lands in an HTML mail client. The
                # submitter's text is data, not markup.
                "Html": {
                    "Data": (
                        '<pre style="font-family:monospace;white-space:pre-wrap">'
                        f"{html.escape(body)}</pre>"
                    ),
                    "Charset": "UTF-8",
                },
            },
        },
    )


def handler(event, context):
    payload, error = _parse_request(event)
    if error:
        return error

    # Honeypot. A real browser never sees this field — it is positioned
    # off screen and excluded from the tab order — so anything in it means
    # an automated form filler. Answer exactly as if the submission had
    # succeeded: a bot told it was caught is a bot that gets retooled.
    if payload.get("website"):
        logger.info("Discarded submission: honeypot field was filled")
        return _response(200, {"message": SUCCESS_MESSAGE})

    fields, error = _validate(payload)
    if error:
        return error

    http_ctx = event.get("requestContext", {}).get("http", {})

    submission_id = str(uuid.uuid4())
    submitted_at = datetime.now(timezone.utc).isoformat(timespec="seconds")

    item = {
        "submission_id": submission_id,
        "submitted_at": submitted_at,
        "name": fields["name"],
        "email": fields["email"],
        "topic": fields["topic"],
        "message": fields["message"],
        # Hashed rather than raw: enough to recognise a repeat submitter
        # or a flood across records, without retaining an identifier for
        # someone who only wanted to send a message.
        "source_ip_hash": hashlib.sha256(
            http_ctx.get("sourceIp", "unknown").encode("utf-8")
        ).hexdigest(),
        "user_agent": (event.get("headers", {}).get("user-agent") or "unknown")[:512],
    }

    # Persisted before the email is attempted, so a transient SES failure
    # loses the notification but never the submission — the record can
    # always be read back out of the table.
    try:
        table.put_item(Item=item)
    except ClientError:
        logger.exception("Failed to persist submission %s", submission_id)
        return _response(500, {"error": GENERIC_ERROR})

    try:
        _send_email(fields, submission_id, submitted_at)
    except ClientError:
        # Deliberately still a success from the submitter's point of view.
        # Their message is stored and will be read; asking them to send it
        # again would only produce a duplicate record.
        logger.exception("Stored submission %s but SES send failed", submission_id)
        return _response(200, {"message": SUCCESS_MESSAGE})

    logger.info("Accepted submission %s (%s)", submission_id, fields["topic"])
    return _response(200, {"message": SUCCESS_MESSAGE})
