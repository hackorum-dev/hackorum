# Privacy Policy

Last updated: 6 November 2026

This policy explains how Hackorum ("we", "us") processes personal data, and what rights you have under the EU General Data Protection Regulation (GDPR).

Hackorum is a reader and tracker for PostgreSQL development. Most of what it shows is a copy of public sources: the PostgreSQL mailing lists, the PostgreSQL git repository, the commitfest app, and the postgresql.org website. Those sources have their own privacy policies, linked below. The only data we collect ourselves is what registered users give us.

## Data controller

The controller responsible for the processing described here is:

Zsolt Parragi
Email: parragizs@gmail.com

Hackorum is a personal, non-commercial project, there is no company behind it. For any privacy question or request, write to the address above.

## Data we process

### Public PostgreSQL community data

We collect the following from public sources, not from you:

- **Mailing list messages** from the public PostgreSQL mailing lists: sender name and email address, recipients, date, subject, body, and attachments, as published in the official archive.
- **Git commits** from the public PostgreSQL repository: author and committer names and email addresses, and people credited in commit messages (Reviewed-by, Reported-by, ...).
- **Commitfest data** from commitfest.postgresql.org: patch entries, authors, reviewers, committers, and status history.
- **Committer and contributor lists** published on www.postgresql.org.

From this we derive additional data: which email addresses belong to the same person, per-person and per-thread statistics, CI results for posted patches, and the relationship between patch versions (patch lineage) including suggested reviewers. Some of the derived data is produced with the help of an AI model, see [Recipients](#recipients).

**Affiliations.** For the statistics pages we keep, per person, which company they worked for and when. This comes from public sources: the PostgreSQL contributors page, commit messages and email domains, conference and company pages, and public profiles. It is kept as date ranges and can be wrong or out of date. To correct or remove yours, write to the address above; we remove it without asking why.

### Account data

If you register, we process:

- **Identification data:** username, email addresses you add or verify, the display names you choose for them, and a hash of your password if you set one.
- **Google sign-in data**, if you use it: your Google account ID, email address, and basic profile information provided by Google.
- **Email sending authorization**, only if you enable sending replies through Hackorum: OAuth tokens for your Google account, limited to the permission to send email.
- **Content you create:** notes, tags, saved searches, teams, and email drafts.
- **Usage data:** which messages you have read, starred and ignored threads, notifications, preferences, and the time of your last login.
- **Administrative records:** a log of actions administrators take on accounts (for example attaching an email address to an account, or merging two people).

### Technical data

- **Server logs:** your IP address, requested URL, time, and browser user agent.
- **Analytics:** we use a self-hosted instance of [Umami](https://umami.is/), which records page views, referrers, browser, operating system, and country. It does not use cookies and does not store IP addresses.
- **Performance data:** render times per page, without any user information.

## Purposes and legal bases

| Purpose | Data | Legal basis |
|---|---|---|
| Mirroring, indexing and analysing PostgreSQL development | Public community data and data derived from it | Legitimate interest (Art. 6(1)(f) GDPR) in making the public PostgreSQL development process easier to follow |
| Publishing monthly dumps of the public data | Public community data and data derived from it | Legitimate interest (Art. 6(1)(f) GDPR), same as above |
| Providing your account and its features | Account data | Performance of a contract (Art. 6(1)(b) GDPR) |
| Sending email on your behalf | Email sending authorization, drafts | Consent (Art. 6(1)(a) GDPR), which you can withdraw at any time in Settings or in your Google account |
| Security, abuse prevention and debugging | Server logs, administrative records | Legitimate interest (Art. 6(1)(f) GDPR) in operating a secure service |
| Understanding how the site is used | Analytics, performance data | Legitimate interest (Art. 6(1)(f) GDPR) in improving the site |

We don't use your data for advertising, we don't sell it, and we don't make decisions about you based solely on automated processing that have legal or similarly significant effects (Art. 22 GDPR).

## Where the public data comes from

If you have posted to a PostgreSQL mailing list, committed to PostgreSQL, or participated in a commitfest, your data was obtained from these sources:

- PostgreSQL mailing list archives: [postgresql.org/list](https://www.postgresql.org/list/)
- PostgreSQL git repository: [git.postgresql.org](https://git.postgresql.org/gitweb/?p=postgresql.git)
- Commitfest app: [commitfest.postgresql.org](https://commitfest.postgresql.org/)
- Contributor and committer lists: [postgresql.org/community/contributors](https://www.postgresql.org/community/contributors/)

These are operated by the PostgreSQL project, whose own [privacy policy](https://www.postgresql.org/about/policies/privacy/) applies to them. Hackorum is not affiliated with the PostgreSQL Global Development Group. If something is removed from the official archive, it is not removed here automatically, so please let us know.

## Recipients

We don't share personal data with third parties, except for the service providers below, who process it on our behalf:

| Provider | Purpose | Data | Location |
|---|---|---|---|
| Hetzner Online GmbH | Server hosting | All data described in this policy | Helsinki, Finland (EU) |
| Mailgun (Sinch) | Delivering verification and notification emails | Your email address and the email contents | EU region |
| Google | Sign-in and sending email, only if you use them | See [Google's privacy policy](https://policies.google.com/privacy) | United States |
| OpenAI | AI-assisted analysis of patches and mailing list threads | Public community data only, never account data | United States |

Transfers to the United States rely on the EU-US Data Privacy Framework or the European Commission's standard contractual clauses.

Public community data, including data derived from it, is also published as monthly database dumps. Account data is never included in them.

Inside Hackorum, your account data is visible as follows: read state, stars, saved searches and drafts are only visible to you. Notes are visible to the people and teams you mention, or to everybody if you make them global. Members of a team can see each other's reading activity in that team. Administrators can access account data when needed to operate the site.

## Retention

- **Public community data:** for as long as Hackorum runs, matching the official archives.
- **Account data:** until you delete your account, see [Deleting your account](#deleting-your-account).
- **Unverified registrations:** deleted after 3 days.
- **Verification and password reset tokens:** deleted shortly after they expire.
- **Server logs:** at most 12 months.
- **Backups and dumps:** kept for 12 months, then deleted. Data you delete stays in older backups until they expire.

## Deleting your account

You can delete your account at any time in **Settings > Delete Account**. This deletes:

- your login methods (password and Google sign-in), and revokes any email sending authorization,
- email addresses you added that never appeared in the public archive,
- your notes (except global notes, see below), saved searches, stars, read state, drafts, notifications, and preferences,
- your team memberships.

What remains:

- **Public community data**, including messages you sent to the mailing lists, either directly or through Hackorum. Your archive email addresses are detached from your account, as they were before you registered.
- **Global notes** you wrote stay visible, as they were shared with everybody, but they are shown as written by "Deleted user".
- **Your username stays reserved**, so nobody can register it later and impersonate you.
- **Administrative records**, kept for accountability.

If you want global notes or anything from the archive removed as well, contact us.

## Your rights

Under the GDPR you have the right to:

- **access** the personal data we hold about you (Art. 15),
- **rectification** of inaccurate data (Art. 16),
- **erasure** (Art. 17),
- **restriction** of processing (Art. 18),
- **data portability** (Art. 20),
- **object** to processing based on legitimate interest (Art. 21),
- **withdraw consent** at any time, without affecting the lawfulness of processing before the withdrawal (Art. 7(3)).

Most account data can be viewed, changed, or deleted directly in Settings. For anything else, including a copy of your data, contact us at the address above. We respond within one month.

This applies to the public community data too: if you appear in the archive, you can ask us to correct how your name and addresses are grouped, or object to the processing of your data. As the data is already public, removing it from Hackorum doesn't remove it from the original sources, you have to contact the PostgreSQL project for that.

You also have the right to lodge a complaint with a data protection supervisory authority, in particular in the EU member state where you live or work.

## Cookies and local storage

Hackorum sets a single cookie, which keeps you logged in for up to 30 days. It is strictly necessary for the service to work, so it doesn't need consent. Your light/dark theme choice is stored in your browser's local storage and never sent to us. We don't use advertising or tracking cookies, and our analytics work without cookies.

## Security

All traffic is encrypted with HTTPS. Passwords are stored as salted hashes, and email sending tokens are encrypted at rest. Access to the servers and the database is limited to the administrators.

## Changes to this policy

When this policy changes, we update this page and the date at the top.
If a change significantly affects how we use your data, we will also announce it on the site.
