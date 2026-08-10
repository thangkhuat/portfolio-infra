/**
 * Contact form submission for thangkhuat.dev.
 *
 * Posts to /api/contact, which CloudFront routes to a Lambda function URL
 * (see the routing section of main.tf). Same origin as this page, so
 * there is no CORS preflight and no AWS hostname in page source.
 *
 * The one non-obvious requirement is the payload hash. CloudFront signs
 * the request it forwards to Lambda, but it does NOT hash the body --
 * AWS's documentation puts that on the caller:
 *
 *   "If you use PUT or POST methods with your Lambda function URL, your
 *    users must compute the SHA256 of the body and include the payload
 *    hash value of the request body in the x-amz-content-sha256 header
 *    when sending the request to CloudFront. Lambda doesn't support
 *    unsigned payloads."
 *
 * CloudFront signs whatever value it is handed. Omit the header and every
 * POST fails signature validation -- while GET keeps working, because a
 * GET has no body to hash. That asymmetry is what makes the failure hard
 * to place: the error talks about signatures and credentials, and the
 * routing looks correct because it is.
 */

const ENDPOINT = "/api/contact";

const MESSAGES = {
  offline: "You appear to be offline. Check your connection and try again.",
  failed: "Couldn't send that. Please email me directly instead.",
  sending: "Sending…",
};

/**
 * SHA-256 of the given bytes, as lowercase hex.
 *
 * Takes bytes rather than a string on purpose: the caller encodes once
 * and sends the very same bytes, so the hash cannot describe a body that
 * differs from the one transmitted. See buildBody().
 */
export async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Collect submitted fields into the shape the handler expects.
 *
 * Takes a FormData rather than the <form> element, so the DOM stays at
 * the edge of this module: `new FormData(formElement)` needs a browser,
 * but a FormData built by hand does not, which lets the tests exercise
 * this exact code path instead of a stubbed imitation of it.
 *
 * `website` is the honeypot and is deliberately kept: the server can
 * only recognise a bot if the field arrives filled in. Stripping it here
 * would disable the check entirely.
 */
export function buildPayload(data) {
  return {
    name: (data.get("name") || "").toString(),
    email: (data.get("email") || "").toString(),
    topic: (data.get("topic") || "general").toString(),
    message: (data.get("message") || "").toString(),
    website: (data.get("website") || "").toString(),
  };
}

/**
 * Encode a payload exactly once, returning the bytes to hash AND send.
 *
 * The single most important line in this file is that both callers use
 * `bytes`. Re-serialising the object for the fetch body -- even with the
 * same JSON.stringify -- would mean the hash describes one byte string
 * and the request carries another. Key order, unicode escaping or a
 * whitespace change is enough to diverge, and the resulting failure
 * surfaces as an opaque signature mismatch that points nowhere near
 * serialisation.
 */
export function buildBody(payload) {
  return new TextEncoder().encode(JSON.stringify(payload));
}

/** POST the submission, returning the parsed response. Throws on transport failure. */
export async function submit(data, fetchImpl = fetch) {
  const bytes = buildBody(buildPayload(data));
  const hash = await sha256Hex(bytes);

  const response = await fetchImpl(ENDPOINT, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-amz-content-sha256": hash,
    },
    body: bytes,
  });

  let parsed = {};
  try {
    parsed = await response.json();
  } catch {
    // A signature rejection comes back as XML from Lambda, not JSON.
    // Fall through to the generic message rather than surfacing it.
  }

  return { ok: response.ok, status: response.status, payload: parsed };
}

function init() {
  const form = document.getElementById("contact-form");
  if (!form) return;

  const button = document.getElementById("cf-submit");
  const status = document.getElementById("cf-status");

  const setStatus = (text, state) => {
    status.textContent = text;
    status.classList.remove("is-ok", "is-error");
    if (state) status.classList.add(state);
  };

  form.addEventListener("submit", async (fired) => {
    fired.preventDefault();

    // The markup carries `novalidate` so this runs on our terms rather
    // than the browser blocking submit before the handler is reached.
    if (!form.checkValidity()) {
      form.reportValidity();
      return;
    }

    button.disabled = true;
    setStatus(MESSAGES.sending, null);

    try {
      const { ok, payload } = await submit(new FormData(form));
      if (ok) {
        setStatus(payload.message || "Thanks — your message has been sent.", "is-ok");
        form.reset();
      } else {
        // The handler returns a specific, safe message for validation
        // failures; anything else falls back to the generic one.
        setStatus(payload.error || MESSAGES.failed, "is-error");
      }
    } catch {
      setStatus(navigator.onLine === false ? MESSAGES.offline : MESSAGES.failed, "is-error");
    } finally {
      button.disabled = false;
    }
  });
}

// Guarded so the module can be imported by the test runner, where there
// is no document to wire up.
if (typeof document !== "undefined") init();
