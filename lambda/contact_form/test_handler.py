"""Unit tests for the contact form handler.

Run from the repository root:

    py -m unittest discover -s lambda/contact_form

Note the start directory. `-s lambda` discovers nothing and still reports
OK — `lambda` is a Python reserved word, so the directory cannot be
imported as a package and recursion silently finds zero tests.

boto3 is stubbed into sys.modules before the handler is imported, rather
than being imported for real. Two reasons, and neither is convenience:

  * The suite runs on a clone with nothing but Python installed. boto3
    ships in the Lambda runtime, so a local copy would only be a second
    version to keep in sync.
  * No test can reach AWS even by accident. There are no credentials in
    play and no region to resolve.

botocore.exceptions is stubbed alongside it, because the handler catches
ClientError by name — leaving the real one in place while boto3 is fake
would mean the except clauses never match what these tests raise.
"""

import json
import logging
import os
import sys
import types
import unittest
from unittest.mock import MagicMock

# --- Stubbing, before the handler is imported ------------------------


class ClientError(Exception):
    """Stands in for botocore's ClientError.

    The real one needs an error_response dict and an operation name to
    construct. Nothing here inspects either, so a plain Exception subclass
    is a truthful stand-in for the only behaviour under test: that the
    handler catches AWS failures and translates them.
    """


_botocore = types.ModuleType("botocore")
_botocore_exceptions = types.ModuleType("botocore.exceptions")
_botocore_exceptions.ClientError = ClientError
_botocore.exceptions = _botocore_exceptions

sys.modules["boto3"] = MagicMock()
sys.modules["botocore"] = _botocore
sys.modules["botocore.exceptions"] = _botocore_exceptions

# The handler reads these at import time, on purpose — a misconfigured
# function should fail once at cold start, not silently per request.
os.environ["SUBMISSIONS_TABLE"] = "test-contact-submissions"
os.environ["SES_FROM_ADDRESS"] = "noreply@thangkhuat.dev"
os.environ["SES_TO_ADDRESS"] = "owner@example.com"

import handler  # noqa: E402  — must follow the stubbing above

# The failure-path tests deliberately trigger logger.exception, which
# would otherwise print tracebacks that read like the suite is broken.
# Silenced so a real failure is the only thing that stands out.
logging.disable(logging.CRITICAL)


def event(
    body,
    method="POST",
    is_base64=False,
    source_ip="203.0.113.5",
    user_agent="Mozilla/5.0",
):
    """Build a Lambda function URL payload format v2.0 event."""
    if isinstance(body, (dict, list)):
        body = json.dumps(body)
    return {
        "requestContext": {"http": {"method": method, "sourceIp": source_ip}},
        "headers": {"user-agent": user_agent},
        "isBase64Encoded": is_base64,
        "body": body,
    }


VALID = {
    "name": "Ada Lovelace",
    "email": "ada@example.com",
    "topic": "collaboration",
    "message": "Would you like to work together?",
}


class HandlerTestCase(unittest.TestCase):
    def setUp(self):
        # Replaced per test so call counts never leak between cases.
        handler.table = MagicMock()
        handler.ses = MagicMock()

    def body_of(self, response):
        return json.loads(response["body"])

    def assertNothingRecorded(self):
        """No submission stored and no mail sent."""
        handler.table.put_item.assert_not_called()
        handler.ses.send_email.assert_not_called()


# ---------------------------------------------------------------------
# Request handling
# ---------------------------------------------------------------------


class TestRequestHandling(HandlerTestCase):
    def test_get_is_rejected(self):
        response = handler.handler(event(VALID, method="GET"), None)
        self.assertEqual(405, response["statusCode"])
        self.assertNothingRecorded()

    def test_malformed_json_is_rejected(self):
        response = handler.handler(event("{not json"), None)
        self.assertEqual(400, response["statusCode"])
        self.assertNothingRecorded()

    def test_non_object_json_is_rejected(self):
        response = handler.handler(event("[1, 2, 3]"), None)
        self.assertEqual(400, response["statusCode"])
        self.assertNothingRecorded()

    def test_oversized_body_is_rejected_on_length(self):
        oversized = json.dumps({**VALID, "message": "x" * (17 * 1024)})
        response = handler.handler(event(oversized), None)
        self.assertEqual(413, response["statusCode"])
        self.assertNothingRecorded()

    def test_base64_encoded_body_is_decoded(self):
        import base64 as b64

        encoded = b64.b64encode(json.dumps(VALID).encode()).decode()
        response = handler.handler(event(encoded, is_base64=True), None)
        self.assertEqual(200, response["statusCode"])
        handler.table.put_item.assert_called_once()

    def test_response_is_never_cached(self):
        response = handler.handler(event(VALID), None)
        self.assertEqual("no-store", response["headers"]["cache-control"])

    def test_no_cors_headers_are_returned(self):
        # The form is same-origin via CloudFront. A CORS header appearing
        # here would mean someone had started exposing this cross-origin.
        response = handler.handler(event(VALID), None)
        lowered = {k.lower() for k in response["headers"]}
        self.assertNotIn("access-control-allow-origin", lowered)


# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------


class TestValidation(HandlerTestCase):
    def test_missing_name_is_rejected(self):
        payload = {k: v for k, v in VALID.items() if k != "name"}
        response = handler.handler(event(payload), None)
        self.assertEqual(400, response["statusCode"])
        self.assertNothingRecorded()

    def test_blank_name_is_rejected(self):
        response = handler.handler(event({**VALID, "name": "   "}), None)
        self.assertEqual(400, response["statusCode"])
        self.assertNothingRecorded()

    def test_invalid_email_is_rejected(self):
        for bad in ["ada", "ada@", "@example.com", "ada@example", "a b@example.com"]:
            with self.subTest(email=bad):
                handler.table.reset_mock()
                response = handler.handler(event({**VALID, "email": bad}), None)
                self.assertEqual(400, response["statusCode"])
                handler.table.put_item.assert_not_called()

    def test_missing_message_is_rejected(self):
        payload = {k: v for k, v in VALID.items() if k != "message"}
        response = handler.handler(event(payload), None)
        self.assertEqual(400, response["statusCode"])
        self.assertNothingRecorded()

    def test_overlong_message_is_rejected(self):
        response = handler.handler(event({**VALID, "message": "x" * 5001}), None)
        self.assertEqual(400, response["statusCode"])
        self.assertNothingRecorded()

    def test_unknown_topic_falls_back_to_general(self):
        handler.handler(event({**VALID, "topic": "../../etc/passwd"}), None)
        stored = handler.table.put_item.call_args.kwargs["Item"]
        self.assertEqual("general", stored["topic"])

    def test_message_may_contain_newlines(self):
        # Unlike name and email, the message is not header-bound.
        response = handler.handler(
            event({**VALID, "message": "line one\nline two"}), None
        )
        self.assertEqual(200, response["statusCode"])


# ---------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------


class TestSecurity(HandlerTestCase):
    def test_newline_in_name_is_rejected(self):
        # Email header injection: name reaches the SES Subject, so a
        # newline would let a submitter append their own Bcc line and
        # relay DKIM-signed mail from this domain.
        injected = "Ada\r\nBcc: attacker@example.com"
        response = handler.handler(event({**VALID, "name": injected}), None)
        self.assertEqual(400, response["statusCode"])
        self.assertNothingRecorded()

    def test_newline_in_email_is_rejected(self):
        # email reaches Reply-To, so the same vector applies — but note
        # this is defence in depth, not a second test of the CR/LF guard.
        # Deleting that guard leaves this test green, because the address
        # format check rejects the value independently: \s covers \n, so
        # the pattern cannot match across the injected line break.
        #
        # Found by mutation, not by reading the code. The assertion is on
        # the outcome, which is what actually matters — the value never
        # reaches a header either way.
        injected = "ada@example.com\nBcc: attacker@example.com"
        response = handler.handler(event({**VALID, "email": injected}), None)
        self.assertEqual(400, response["statusCode"])
        self.assertNothingRecorded()

    def test_honeypot_is_discarded_silently(self):
        response = handler.handler(event({**VALID, "website": "spam.example"}), None)
        # Indistinguishable from success: telling a bot it was caught is
        # free tuning information for whoever runs it.
        self.assertEqual(200, response["statusCode"])
        self.assertEqual(handler.SUCCESS_MESSAGE, self.body_of(response)["message"])
        self.assertNothingRecorded()

    def test_server_error_leaks_no_internal_detail(self):
        handler.table.put_item.side_effect = ClientError(
            "AccessDeniedException: User is not authorized to perform "
            "dynamodb:PutItem on resource arn:aws:dynamodb:ap-southeast-2:..."
        )
        response = handler.handler(event(VALID), None)
        self.assertEqual(500, response["statusCode"])
        text = response["body"]
        for leak in ["AccessDenied", "arn:aws", "dynamodb:PutItem", "Traceback"]:
            self.assertNotIn(leak, text)

    def test_client_cannot_set_server_generated_fields(self):
        forged = {
            **VALID,
            "submission_id": "attacker-chosen-id",
            "submitted_at": "1999-01-01T00:00:00+00:00",
            "source_ip_hash": "forged",
        }
        handler.handler(event(forged), None)
        stored = handler.table.put_item.call_args.kwargs["Item"]
        self.assertNotEqual("attacker-chosen-id", stored["submission_id"])
        self.assertNotEqual("1999-01-01T00:00:00+00:00", stored["submitted_at"])
        self.assertNotEqual("forged", stored["source_ip_hash"])

    def test_source_ip_is_stored_hashed_not_raw(self):
        handler.handler(event(VALID, source_ip="198.51.100.9"), None)
        stored = handler.table.put_item.call_args.kwargs["Item"]
        self.assertNotIn("198.51.100.9", json.dumps(stored))
        self.assertEqual(64, len(stored["source_ip_hash"]))

    def test_reply_to_is_the_submitter_not_the_noreply_sender(self):
        handler.handler(event(VALID), None)
        sent = handler.ses.send_email.call_args.kwargs
        self.assertEqual([VALID["email"]], sent["ReplyToAddresses"])
        self.assertEqual("noreply@thangkhuat.dev", sent["Source"])


# ---------------------------------------------------------------------
# Failure modes
# ---------------------------------------------------------------------


class TestFailureModes(HandlerTestCase):
    def test_dynamodb_failure_returns_500_and_skips_the_email(self):
        handler.table.put_item.side_effect = ClientError("throughput exceeded")
        response = handler.handler(event(VALID), None)
        self.assertEqual(500, response["statusCode"])
        # Nothing was kept, so there is nothing to notify about.
        handler.ses.send_email.assert_not_called()

    def test_ses_failure_still_succeeds_because_the_record_survived(self):
        handler.ses.send_email.side_effect = ClientError("MessageRejected")
        response = handler.handler(event(VALID), None)
        # The submission is safe in the table and can be read out later.
        # Asking the visitor to resend would only duplicate the record.
        self.assertEqual(200, response["statusCode"])
        self.assertEqual(handler.SUCCESS_MESSAGE, self.body_of(response)["message"])
        handler.table.put_item.assert_called_once()

    def test_successful_submission_stores_then_sends(self):
        response = handler.handler(event(VALID), None)
        self.assertEqual(200, response["statusCode"])
        handler.table.put_item.assert_called_once()
        handler.ses.send_email.assert_called_once()
        stored = handler.table.put_item.call_args.kwargs["Item"]
        self.assertEqual(VALID["name"], stored["name"])
        self.assertEqual("collaboration", stored["topic"])


if __name__ == "__main__":
    unittest.main()
