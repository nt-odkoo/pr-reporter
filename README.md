# PR Daily Report Generator

Багын гишүүдийн өдөр тутмын PR идэвхийг Markdown report болгон гаргана. PR-уудын summary-г Gemini CLI ашиглан автоматаар бичнэ.

## Шаардлага

- [GitHub CLI (`gh`)](https://cli.github.com/) — authenticated
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) — `npm install -g @google/gemini-cli`
- `jq` — JSON processing

## Тохиргоо

### `conf/repos.conf`
Мониторлох repo-уудын жагсаалт (мөр бүрт нэг):
```
myorg/backend-api
myorg/frontend-app
myorg/mobile-app
```

### `conf/ignore.conf`
Ignore хийх GitHub username-ууд (мөр бүрт нэг, case-insensitive):
```
dependabot[bot]
renovate[bot]
```

## Ашиглах

```bash
# Тодорхой өдрийн report
./generate-report.sh --date 2026-04-15

# Help
./generate-report.sh --help
```

## Report

`reports/daily-report-YYYY-MM-DD.md` файл үүснэ.

### Жишээ report бүтэц:

```markdown
# Daily PR Report — 2026-04-15

## myorg/backend-api — johndoe

**Summary:** John focused on improving the authentication flow,
adding OAuth2 support and fixing token refresh edge cases.

| Link | Status | Title |
|------|--------|-------|
| [#123](https://github.com/myorg/backend-api/pull/123) | ✅ Merged | Add OAuth2 provider |
| [#125](https://github.com/myorg/backend-api/pull/125) | 🔵 Open | Fix token refresh race condition |

## myorg/backend-api — janedoe
...
```