---
name: whats-ready
description: Answer "what's ready for me?" — list this app's open PRs with live CI state and exactly what each needs from Dylan. Use when he asks what's ready, what's pending, or what to review.
---

# What's ready

1. List open PRs in this repo (authored by Dylan or his agents). Check each one's live CI on the head commit; don't trust a cached status.
2. Sort them into:
   - **Ready to merge:** green, release checkbox filled in, nothing outstanding.
   - **Needs a decision:** a question only Dylan can answer. State the question in one sentence.
   - **In progress:** red or still running. Say what's failing and whether someone is on it.
3. For each PR give a link, one line on what it does, and the one thing it needs. Include screenshots for UI PRs.

Stay in this app's lane: don't report sibling-app work unless asked. Never merge; Dylan does.
