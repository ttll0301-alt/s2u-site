# S2:U (Sustain to You) site

Live: https://sustaintoyou.com — GitHub Pages, repo `ttll0301-alt/s2u-site`, branch `main`, served from `/`.
Single-file static site (`index.html`) with data arrays inline. No build step. Every push to `main` goes live in ~1 min.

## Where things live (index.html)

| Request | Edit | Array |
|---|---|---|
| 운동 프로그램 반영 | `sessions` | around line 1443 |
| 행사 추가/수정 | `events` | around line 1502 |
| 사진 세션 | `photoSessions` | around line 1860 |
| 영상/아카이브 (FYF 등) | `WORKS` | around line 2025 |

Line numbers drift: `grep -n "const sessions\|const events\|const photoSessions\|const WORKS" index.html`.
Copy an existing entry's shape exactly when adding one; keep date format `YYYY.MM.DD`.

## Media

- Files sit in the repo root next to `index.html`; videos as `.mp4` with a same-name `.jpg` poster (`fyf-<slug>.mp4` / `.jpg`).
- Keep each file well under 100 MB (GitHub hard limit); aim for videos < 5 MB, photos < 300 KB.
- Resize photos with `sips -Z 1600 in.jpg --out out.jpg` (no ffmpeg installed).

## Tools

- `scripts/prep-media.sh <slug> <files...>` — resize photos, copy video + poster, then runs the check.
- `scripts/check-site.py` — must print OK before every push (missing media, >95 MB files, CNAME, data arrays).
- `scripts/export-content.py` — refreshes `~/s2u-data/` (content-bank.md, works.csv, partners.csv) for captions, pitches, newsletters. Private, outside the repo.
- Skills (user-level): `s2u-ship` (apply + deploy + verify), `s2u-media`, `s2u-content` (drafts only, never posts).

## Ship it

```
cd ~/s2u-site
git pull --rebase
# edit index.html / add media
git add -A && git commit -m "<what changed>" && git push
```

Push uses the repo deploy key (`~/.ssh/s2u_deploy`, host alias `github-s2u`). Never use or ask for account passwords/tokens.
After pushing, verify: `curl -s https://sustaintoyou.com | grep -c "<new title>"` (allow ~1 min).

## Do not touch

- `CNAME` (domain binding), DNS, GitHub Pages settings.
- `index (1).html` is an old copy; ignore it.
- This repo is public: nothing private in commits or in this file.
