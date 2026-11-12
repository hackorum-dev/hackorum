# Hackorum API guide

For language models and tool authors. Exact shapes are in the OpenAPI document, see the end.

## What this is

Hackorum is a web archive of the PostgreSQL mailing lists. It also applies each patchset posted there on PostgreSQL's master, pushes the result as a git branch and runs CI on it. The API reads threads, messages, patchsets, branches, CI runs, commits and people, and can prepare a draft of a reply that only its owner can send, on the site.

All paths below are relative to `/api/v1` on the site, so `/topics` is `https://hackorum.dev/api/v1/topics`. The paths say `topics`, a topic is a thread. In a record `url` is the record in the API, `html_url` the page on the site.

## Authentication

A token is optional. The user creates it on the site (Settings, API tokens), and it is sent as a header:

```
Authorization: Bearer hko_...
```

Never put a token into a URL, there is no query parameter for it. What a token unlocks:

- a higher rate limit
- the owner's own state in `me` on threads and messages, and the search selectors about the owner
- the private notes the owner can see, saved searches, the activity list
- drafts
- lineage data, when the account has that feature

A token that is invalid, expired or revoked is answered with 401 `invalid_token`, never anonymously. `/me`, the paths under it and `/drafts` need a token, without one they give 401 `token_required`.

## Ground rules

- Responses are JSON, except attachment content, this guide and the YAML form of the OpenAPI document.
- An operation takes only the query parameters it documents. An unknown one, or one with an empty value, is 400 `invalid_parameter`: leave a parameter out instead of sending it empty.
- Every error has one shape. Programs read `code`, `message` is for people:

```
{"error": {"code": "invalid_parameter", "message": "unknown parameter: foo"}}
```

- Codes worth handling:
  - 429 `rate_limited`: wait the seconds in the `Retry-After` header, then repeat.
  - 400 `query_too_expensive`: a database statement ran longer than 5 seconds. Narrow the search, a date selector helps.
  - 400 `invalid_cursor`: the cursor is malformed or from another request. Start that list again.
  - 410 `cursor_expired`: on `/events` only, see "Following changes".
  - 401 `token_required`: this request needs a token.
  - 403 `feature_required`: the account does not have the feature (lineage). A token alone does not help.
  - 409 `conflict`: a draft is being sent, changed since the `updated_at` you gave, or is busy. Read it again and retry.
  - 422 `draft_limit`: too many unsent drafts or attachment bytes. Ask the user to send or delete drafts.
- `/topics/{id}` and the lists under it answer a merged thread with 301 and no body. `Location` is the same request on the thread it was merged into: follow redirects.
- Rate limits: 60 requests a minute per IP address without a token, 600 per token with one. These are the defaults, the `RateLimit-Limit` and `RateLimit-Remaining` headers of every response say what applies.
- No GET changes anything: reading does not mark a thread or a message as read.

## Paging

Lists answer `{"data": [...], "next_cursor": ...}`. `limit` sets the page size: default 50, a value above 200 is lowered to 200. For the next page repeat the same request with `next_cursor` as `cursor`. `next_cursor: null` is the end. A cursor belongs to the request that gave it, the same path and parameters: only `limit` and `body` may change between pages.

3 lists are not paged and refuse `limit` and `cursor`: `/mailing_lists`, `/topics/{id}/commits` and `/me/saved_searches`. `/events` has its own cursor, passed as `since`.

## Reading a thread economically

1. Find the thread: `GET /topics?q=...`. Without `q` it lists threads by last activity. `q` is the search language of the site, at most 500 characters:
   - Bare words match titles and message bodies, `"two words"` is a phrase.
   - Terms are joined with AND. `OR`, parentheses and a leading `-` for "not" work.
   - Selectors are `name:value`: `title:`, `body:`, `from:`, `starter:`, `last_from:`, `list:`, `has:patch`, `has:attachment`, `commitfest:`.
   - Dates: `first_after:`, `messages_after:`, `last_after:` and the same with `_before`, with `2024-01-15`, `2024-01`, `today` or an age like `7d`, `2w`, `3m`, `1y`. Counts: `messages:>10`, `participants:<5`.
   - With a token `unread:me`, `starred:me`, `from:me` (the value is `me`, not `true`). Without a token they match nothing.

   `warnings` names the parts of a query that were skipped. All selectors: the description of the `q` parameter in the OpenAPI document.
2. `GET /topics/{id}` is the thread without its messages: counts, participants, commitfest entries, `ci` for its current patchset, and `links`. `{id}` is the numeric id or the slug.
3. `GET /topics/{id}/messages?body=none&limit=200` is the outline, oldest first. Entries have `body: null` and everything else: `id`, `number`, `sender`, `reply_to_id`, `depth`, `is_patch_submission`, `attachments`. `number` is the position in the thread, from 1; it can change when older mail arrives late. `depth` is the number of replies above the message, 0 for a root.
4. Read only the messages you need: `GET /messages/{id}`. `body=text` (the default) is the text without quoted lines, attribution lines and forwarded originals, `body=full` is the stored body.
5. `GET /topics/{id}/patchsets` lists the messages that carry patches, newest first: `limit=1` is the current version. `files` are the patch files, `changed_paths` the source files they touch. Download a file from its `content_url` (`GET /attachments/{id}/content`): the bytes come as `text/plain` or `application/octet-stream`, not as JSON.
6. `GET /topics/{id}/commits` is what got committed for the thread, a change and its backports as one entry.

`rfc_message_id` is the Message-ID header of a mail. `GET /messages/lookup?rfc_message_id=...` finds the message by it. Percent-encode the value, a `+` is sent as `%2B`. A field named `message_id` is always the numeric id.

## Patches, branches and CI

A branch is the record of hackorum trying to apply one patchset. Each entry of `/topics/{id}/patchsets` has a short `branch` (null when it was never tried) with `id`, `branch_name`, `status` (`applied` or `failed`), `ci_status` and `pushed_at`. `GET /branches/{id}` is the full record.

`GET /branches` lists branches, last changed first, the newest patchset of each thread only. Filters, combined with AND: `topic` (numeric id), `author` (email address), `state`, `ci_status`, `pg_major`, and `current=false` to include patchsets that a newer one replaced.

`state` says where the patchset stands:

- `applies`: applied on the current master and pushed. Says nothing about CI.
- `needs_rebase`: does not apply on the current master. The pushed branch is on the older base in `base_sha`, and `ci_status` is about that base.
- `awaiting_ci`: not pushed yet, or its CI run has not finished. Ask again later.
- `never_applied`: the patches applied nowhere, `failure_stage` and `failure_reason` say why. Nothing to fetch.
- `wont_retry`: frozen, `state_reason` says why (committed, merged thread, base too old, CI skipped). Its last results stay, valid for `base_sha`.

`ci_status` is the CI verdict for the commit that is pushed now (`pushed_head_sha`): `success`, `build_failed`, `tests_failed`, `build_timeout`, `tests_timeout`, `cancelled`, `infra_error` (says nothing about the patches), or not there yet: `queued`, `running`, `pushed_awaiting_ci`, `push_failed`. `ci_none` means hackorum runs no CI for the branch. Null means CI never ran; the filter value for that is `ci_status=none`.

`latest_run` is the last CI run hackorum accepted for the branch. After a new push it is still the run of the previous commit: it describes the pushed commit only when `latest_run.head_sha` equals `pushed_head_sha`. Failed tests are in `latest_run.failed_tests`, earlier runs in `GET /branches/{id}/ci_runs`.

To get the code: `git fetch <git_url> <branch_name>`. The git branch exists only when `pushed_at` is set. To get the Docker image a run built, pull `image_pull_ref`, which names it by digest. `image_ref` is a tag that later runs overwrite.

## Following changes

`GET /events` is the feed of what happened, oldest first. 4 types: `message.received`, `patchset.posted`, `branch.created` (the first try to apply a patchset, later rebases are not reported) and `ci.completed`. Each event has `id`, `type`, `occurred_at`, `recorded_at`, `topic`, `author` and exactly one of `message` (without the body), `patchset`, `branch` or `ci_run`, the record as it is now.

```
since = stored cursor, or "24h" on the first run
loop:
    r = GET /events?since=<since>&types=patchset.posted&limit=200
    if r is 410:                 # cursor_expired
        read again what you track from the list endpoints
        since = "24h"
        continue
    handle r.data
    since = r.next_cursor        # store it
    if not r.has_more:
        sleep 60 seconds or more
```

- The first call takes a duration (`since=24h`, `90m`, `7d`) or an ISO 8601 timestamp. Without `since` it is `since=24h`. After that pass the `next_cursor` of the last response as `since`.
- `next_cursor` is never null, also on an empty page. `has_more: true` means the next page is waiting now.
- Filters: `types` (comma-separated), `topic`, `author`, `list`, `ci_runs`, and with a token `starred=true` and `participating=true`. A cursor is only a position, it works with other filters too.
- Events of the last 5 seconds are held back and come with a later call. Following `next_cursor` gives every event once.
- The feed keeps 90 days. An older position is 410 `cursor_expired`: start over with a duration and read again what you track.
- Poll once a minute or less often.
- By default the feed leaves out CI runs that only repeat the previous verdict of the same patchset: branches are rebased and re-run about daily. `ci_runs=all` gives every run; `ci_run.first_run` and `ci_run.previous_status` tell them apart. A run is reported again if its verdict changes.
- Threads that are only on hidden lists are left out unless `list` names the list.

## Per-user data with a token

- Threads have `me`: `starred`, `ignored`, `status` (`new`, `aware`, `reading`, `read`), `read_count`, `unread_count`, `note_count`. Messages have `me.read`. Without a token `me` is null.
- `/topics` then leaves out the threads the owner ignores.
- `GET /topics/{id}/notes` gives the public notes of a thread, with a token also the private ones the owner wrote or is mentioned in. `message_id` narrows it to one message.
- `GET /me/saved_searches` lists saved searches. Run one with its `topics_url`, which is `/topics` with `saved_search_id` (and `team_id` for a team search).
- `GET /me/activities` is the activity list: new messages in starred threads, notes the owner wrote and notes that mention the owner. `unread=true` gives the unread entries.

## Drafts

The API cannot send mail. It can prepare a reply, and the owner sends it on the site. This needs a token whose account has a Gmail identity that may send (`send_authorized` in `/me`), else the answer is 403 `no_send_identity`.

1. `POST /drafts` with `{"reply_to_message_id": 67890, "body": "..."}` (the id is a placeholder). Optional: `subject` (default: the subject of the message with `Re: `) and `quote`, text of the message that is put in front of `body` as a quotation. The answer is the draft, 201. If the owner already has an unsent draft for that message, it comes back unchanged with 200: change it with PATCH.
2. `PATCH /drafts/{id}` with `subject`, `body` or both. `body` replaces the whole text. Send the `updated_at` you saw last to not overwrite a change made in between: if the draft changed, the answer is 409 `conflict`.
3. `POST /drafts/{id}/attachments` with `{"file_name": "v2-0001-fix.patch", "content_type": "text/x-diff", "content_base64": "..."}`: one file per request, as Base64 inside the JSON. `DELETE /drafts/{id}/attachments/{attachment_id}` takes a file off.
4. `GET /drafts/{id}` reads the draft back, with `recipients`, who a send would go to. They follow from the message and cannot be set.
5. Tell the user to open the `html_url` of the draft: the thread on the site, with the composer open on the draft. The owner reads it there, with its attachments, and sends it or not.
6. `DELETE /drafts/{id}` throws an unsent draft away. `GET /drafts` lists the owner's drafts, `state=in_progress` the unsent ones.

Bodies are JSON with `Content-Type: application/json`. Limits: request body: 4 MB; `subject`: 998 characters; text: 1 MB; `quote`: 100 KB; attachments of one draft: 2 MB of decoded bytes together. Through tokens an account can hold 50 unsent drafts and 20 MB of attachments on them, beyond that the answer is 422 `draft_limit`. A write that waits more than 2 seconds for a draft another request holds is 409 `conflict`.

No operation sends, and a token does not carry that permission. A token can still change a draft until it is sent, but the site refuses to send a draft that changed after the owner confirmed it, and asks to look at it again. So do not edit a draft after you told the user it is ready.

## Lineage

For some threads a language model wrote down how the patchsets derive from each other, which commits came out of the thread and who reviewed what: `GET /topics/{id}/lineage`, a `lineage` field on patchsets, `link_source` and `verdict` on commits. Only accounts with the `patchset_lineage` feature get it (see `features` in `/me`), everyone else gets 403 `feature_required` on the endpoint and no such fields elsewhere. It is model output with a confidence: treat it as a hint, not as fact.

## Operations

| Method | Path | Gives |
|---|---|---|
| GET | `/me` | The caller's account and token |
| GET | `/me/saved_searches` | Saved searches |
| GET | `/me/activities` | Activity list |
| GET | `/mailing_lists` | All mailing lists |
| GET | `/people/{email}` | A person, by address |
| GET | `/people/{email}/topics` | Threads the person wrote in |
| GET | `/people/{email}/patchsets` | Patchsets the person sent |
| GET | `/topics` | Threads, with search |
| GET | `/topics/{id}` | One thread |
| GET | `/topics/{id}/messages` | Messages of a thread |
| GET | `/topics/{id}/patchsets` | Patchsets of a thread |
| GET | `/topics/{id}/commits` | Commits linked to a thread |
| GET | `/topics/{id}/notes` | Notes on a thread |
| GET | `/topics/{id}/lineage` | Lineage of a thread (feature) |
| GET | `/messages/lookup` | A message by Message-ID |
| GET | `/messages/{id}` | A message by id |
| GET | `/attachments/{id}` | Attachment, without content |
| GET | `/attachments/{id}/content` | Attachment bytes |
| GET | `/branches` | Branches |
| GET | `/branches/{id}` | One branch |
| GET | `/branches/{id}/ci_runs` | CI runs of a branch |
| GET | `/events` | The change feed |
| GET | `/drafts` | Drafts |
| POST | `/drafts` | Make a draft of a reply |
| GET | `/drafts/{id}` | One draft |
| PATCH | `/drafts/{id}` | Change subject or text |
| DELETE | `/drafts/{id}` | Delete an unsent draft |
| POST | `/drafts/{id}/attachments` | Attach a file |
| DELETE | `/drafts/{id}/attachments/{attachment_id}` | Take a file off |
| GET | `/openapi.json` | OpenAPI document, JSON |
| GET | `/openapi.yaml` | OpenAPI document, YAML |
| GET | `/guide.md` | This guide |

## Pointers

- `/api/v1/openapi.yaml` (or `/api/v1/openapi.json`): every parameter, field and error code.
- `/api/docs`: the same reference as a page for people.
- `/help/search`: the search language.
