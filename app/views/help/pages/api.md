# API

Hackorum has a JSON API for scripts, tools and AI agents (skills, MCP servers). It gives read access to what the site shows to everybody: threads and their messages, patchsets and their files, the git branches hackorum builds from patchsets with their CI results, the commits linked to a thread, people, and the mailing lists. With a token it also gives what the site shows only to you: your stars and read state, the notes you can see, your saved searches and your activity list.

Almost all of it is reading, with GET. To follow what happens there is one feed to poll, see [Following changes](#following-changes). The one thing the API can write is a draft of a reply: a tool can prepare the mail, you read it on the site and send it there. Drafts that start a new thread are not possible yet, only replies.

It cannot send email, and it never will: there is no send endpoint, and a token does not give that permission. A draft made through the API stays a draft until you press Send in the composer on the site, see [Drafts](#drafts) below.

This page is the introduction. There are two more descriptions:

- The [API reference](/api/docs) has every endpoint, parameter and field.
- The [guide for agents](/api/v1/guide.md) is one short text in plain markdown. Give it to a language model, or to a tool that should use the API, and it knows how.

## First request

The API is under `/api/v1` on this site, and it works without a token. A thread search:

```
curl "https://hackorum.dev/api/v1/topics?q=title:vacuum+has:patch&limit=1"
```

The answer, shortened. The ids and the names are made up, on this page `12345` always stands for the `id` of a thread, `67890` for the `id` of a message and `123` for the `id` of a draft:

```
{
  "data": [
    {
      "id": 12345,
      "title": "Skip unneeded work in vacuum of large tables",
      "url": "https://hackorum.dev/api/v1/topics/12345",
      "html_url": "https://hackorum.dev/topics/12345",
      "last_message_at": "2026-11-05T09:10:19.000Z",
      "message_count": 6,
      "commit_count": 0,
      "creator": { "id": 42, "name": "Alice Example", ... },
      "mailing_lists": [ { "identifier": "pgsql-hackers", "display_name": "hackers" } ],
      "ci": { "state": "applies", "ci_status": "success", "branch_id": 678, ... }
    }
  ],
  "next_cursor": "WyJkNzZmMmZmZCIsIjIwMjYtMTEt...",
  "warnings": []
}
```

Lists always have `data` and `next_cursor`. The paths say `topics`, a topic is a thread. Most records have a `url` (the record in the API) and an `html_url` (the page on the site).

## Tokens

You create a token on the site, at [Settings, API tokens](/settings/api_tokens). The value starts with `hko_` and is shown once, when you create it: copy it then, it is not stored in a readable form. A token can have an expiry date, and you can revoke it on the same page.

Send it in the `Authorization` header:

```
curl -H "Authorization: Bearer hko_..." "https://hackorum.dev/api/v1/me"
```

`/me` tells which account and token the request runs as. The requests under `/me` and `/drafts` need a token, and so do the `starred` and `participating` filters of `/events`. The lineage data needs a token of an account with that feature. Everything else works without one. What a token changes:

- The rate limit is higher, 600 requests per minute instead of 60.
- Threads come with your own state in `me`: starred, ignored, how much you have read, how many notes you can see. Messages say in `me` whether you read them.
- The thread list leaves out the threads you ignore, and its search runs as you, so `starred:me` or `unread:me` work.
- The notes of a thread include the private ones you wrote or are mentioned in, directly or through a team. Without a token only public notes are given.
- You can list your saved searches and run them, and read your activity list.
- The feed can be narrowed to the threads you starred or wrote in.
- You can write, change and delete drafts of replies, and attach files to them, if your account has a Gmail address connected for sending.
- If your account has the lineage feature, you also get the lineage data: how the patchsets of a thread derive from each other and which commits came out of it, written by a language model. It can be wrong, and without the feature these fields are simply not there.

`me` only ever holds your own state, and no response names your teammates. In the search, the name of a team you are in works in the state selectors (`starred:myteam`, `unread:myteam`) as it does on the site: it searches the state of the members taken together. Reading through the API does not mark anything as seen. Drafts are the only thing a token can change.

A token that is wrong, expired or revoked gets a 401 with the code `invalid_token`. The request is not answered anonymously instead, so a client notices a dead token.

## Rules for clients

- Rate limits are per minute: 60 requests per IP address without a token, 600 per token with one. They are counted per server process, so do not rely on the exact number. Every response has `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset` (seconds). Over the limit you get a 429 with the code `rate_limited`, and `Retry-After` says how many seconds to wait.
- Lists are paged. `limit` sets the page size, 50 by default and at most 200. To get the next page, repeat the same request with the `next_cursor` of the answer as `cursor`. `next_cursor: null` means the end. A cursor only works with the path and parameters of the request that gave it. Three short lists are not paged and refuse `limit` and `cursor`: `/mailing_lists`, `/topics/{id}/commits` and `/me/saved_searches`.
- A database query that runs longer than 5 seconds is stopped, and the answer is a 400 with the code `query_too_expensive`. A broad search is the usual cause, narrow it (a date selector helps).
- Parameters are checked. One that the request does not document, or one with an empty value, is a 400 with the code `invalid_parameter`. Leave a parameter out instead of sending it empty.
- Requests that write take a JSON body with `Content-Type: application/json`, at most 4 MB. Form bodies are not read, and `_method` or `X-HTTP-Method-Override` do nothing: use the real HTTP method.
- A thread that was merged into another one answers with a 301, `Location` is the same request on the thread it was merged into. Follow redirects (`curl -L`).
- Errors always have the same form, `{"error": {"code": "...", "message": "..."}}`. Programs should look at `code`, `message` is for people.

## What to ask for

The paths below are relative to `/api/v1`.

| You want | Request |
|----------|---------|
| Search threads | `GET /topics?q=...`, with the [search syntax](/help/search) of the site |
| The outline of a thread, without the text | `GET /topics/{id}/messages?body=none` |
| One message with its text | `GET /messages/{id}`, add `body=full` to keep the quoted lines |
| A message by its Message-ID header | `GET /messages/lookup?rfc_message_id=...` |
| The latest patchset of a thread and its files | `GET /topics/{id}/patchsets?limit=1`, then the `content_url` of each entry in `files` |
| Branches that failed their tests | `GET /branches?ci_status=tests_failed`, the tests are in `latest_run.failed_tests` |
| What happened since your last call | `GET /events?since=...`, see [Following changes](#following-changes) |
| Earlier CI runs of a branch | `GET /branches/{id}/ci_runs` |
| What got committed for a thread | `GET /topics/{id}/commits` |
| The recent patchsets of a person | `GET /people/{email}/patchsets` |
| The notes on a thread | `GET /topics/{id}/notes` |
| Your saved searches, and the threads of one | `GET /me/saved_searches`, then the `topics_url` of an entry |
| What happened in the threads you starred, and notes that mention you | `GET /me/activities`, add `unread=true` for the new entries |
| How the patchsets of a thread derive from each other (lineage feature) | `GET /topics/{id}/lineage` |
| Your drafts, the sent ones too | `GET /drafts`, add `state=in_progress` for the unsent ones |
| Prepare a reply to a message | `POST /drafts`, see [Drafts](#drafts) |
| Attach a patch to a draft | `POST /drafts/{id}/attachments` |

`{id}` of a thread is its numeric id or its slug. A Message-ID has to be percent-encoded, a `+` in it is sent as `%2B`.

## Examples

### Reading a thread

A long thread has hundreds of messages, and reading all of them with their text is rarely needed. Ask for the outline first. Take an `id` from the search result and put it in the place of `12345`:

```
curl -L "https://hackorum.dev/api/v1/topics/12345/messages?body=none&limit=200"
```

Each entry has `id`, `number`, `sender`, `created_at`, `reply_to_id` and `depth`, which is enough to see who answered whom. `is_patch_submission` marks the messages that carry patches, and `attachments` lists the files. Then read only the messages you need, by the `id` of an entry (`67890` here):

```
curl "https://hackorum.dev/api/v1/messages/67890"
```

`body` is the text without quoted lines, attribution lines and forwarded originals. Add `?body=full` for the message as it was sent.

### Branches with failed tests

```
curl "https://hackorum.dev/api/v1/branches?ci_status=tests_failed&limit=20"
```

Look at `topic` for the thread, `latest_run.failed_tests` for the names of the failed tests and `latest_run.github_url` for the run on GitHub. `latest_run` describes the commit that is pushed now only when `latest_run.head_sha` equals `pushed_head_sha`. To try the branch yourself, `git fetch <git_url> <branch_name>`.

Add `author=` with an email address to see only the patchsets of one person, or `topic=` with the numeric id of a thread.

### The latest patchset of a thread

```
curl -L "https://hackorum.dev/api/v1/topics/12345/patchsets?limit=1"
```

Patchsets come newest first, so this is the current version. `files` are the patch files, each with a `content_url` to download it, `changed_paths` are the source files the patches touch, and `branch` says whether hackorum could apply it and what CI said.

## Following changes

`/events` is a feed of what happened: a message arrived, a patchset was posted, a branch was created, a CI run finished. The patchsets of the last day:

```
curl "https://hackorum.dev/api/v1/events?since=24h&types=patchset.posted"
```

The answer has a `next_cursor`, also when nothing happened: store it, and pass it as `since` in the next call to get only what came after it. The feed keeps 90 days, a cursor older than that gets a 410 with the code `cursor_expired`, and then you start over with a duration like `24h`.

By default the feed leaves out CI runs that only repeat the previous verdict of the same patchset: every live branch is rebased and tested again about once a day, and most of these runs say what the one before said. Add `ci_runs=all` to get every run. A run is reported again if its verdict changes.

Once a minute is often enough to ask. `author=` with an email address and `topic=` with the numeric id of a thread narrow the feed, and with a token `starred=true` and `participating=true` do.

## Drafts

A tool can prepare a reply for you, with its patches attached. It cannot send it. This needs a token, and an account with a Gmail address connected for sending (`send_authorized` in `/me`).

Make the draft of a reply to a message:

```
curl -X POST -H "Authorization: Bearer hko_..." -H "Content-Type: application/json" \
  -d '{"reply_to_message_id": 67890, "body": "Thanks, v3 looks good to me."}' \
  "https://hackorum.dev/api/v1/drafts"
```

The answer is the draft, with a 201. `subject` is filled in from the message when you leave it out, `quote` puts quoted text of the message in front of `body`, and `recipients` shows who the mail would go to. You have one unsent draft per message: if there is one already, it comes back unchanged with a 200. `PATCH` on the `url` of the draft changes `subject` or `body`, `DELETE` throws an unsent draft away.

Attach a file, as Base64 inside the JSON:

```
curl -X POST -H "Authorization: Bearer hko_..." -H "Content-Type: application/json" \
  -d "{\"file_name\": \"v4-0001-fix.patch\", \"content_type\": \"text/x-diff\", \"content_base64\": \"$(base64 -w0 v4-0001-fix.patch)\"}" \
  "https://hackorum.dev/api/v1/drafts/123/attachments"
```

The answer is the draft again, with the file in `attachments`. The file name and the content type are cleaned before they are stored (a content type keeps at most a `charset`), so look at the answer for what was stored.

The draft then waits on the site. Open its `html_url`: it is the thread, with the composer open on your draft. You read it there, change it if you want, and send it. What the site does at that step:

- The composer and the confirmation dialog say "Drafted via API" or "Edited via API", with the name of the token.
- Before sending, the confirmation dialog shows the recipients, the full text and the attachments, and you can download each attachment to check it.
- A token can still change the draft while you look at it. If it changed after the confirmation was shown, the site refuses to send and asks you to look again, so what goes out is what you saw.

The limits: a subject has at most 998 characters and the text 1 MB. The attachments of one draft can have 2 MB together, one request 4 MB. Through tokens an account can hold 50 unsent drafts and 20 MB of attachments on them, after that the answer is a 422 with the code `draft_limit` until you send or delete some.

## Reference

The full description of the API is an OpenAPI document:

- [/api/v1/openapi.yaml](/api/v1/openapi.yaml)
- [/api/v1/openapi.json](/api/v1/openapi.json)

It describes every endpoint, parameter, field and error code, and it is the place to look when this page does not answer a question. It can also be given to tools that generate clients or MCP servers from an OpenAPI description. The [API reference](/api/docs) is the same document as a page to read, and [/api/v1/guide.md](/api/v1/guide.md) is the short version for agents.

The `q` parameter of the thread search uses the search language of the site, see the [Advanced Search Guide](/help/search). The selectors about you need a token and take `me` as the value: `unread:me`, `starred:me`, `from:me`, ... (not `unread:true`). Without a token they match nothing, and the answer says so in `warnings`.

## Stability

The API is new. This is version 1, and the version is part of the path. Fields may still be added to the answers, so a client should ignore fields it does not know. There is no deprecation policy yet. If something is missing or does not work as described, please tell me.
