#!/usr/bin/env python3
"""Build the prep question bank.

LeetCode requests follow vscode-leetcode and vsc-leetcode-cli (both MIT):
the anonymous /api/problems/algorithms/ list, the getQuestionDetail GraphQL
query, cookie headers from the CLI's signOpts, and the globalData login check.
This script reimplements those requests. It does not vendor either project.

Exit codes: 0 ok, 1 error, 3 LeetCode asked for a login.
"""
from __future__ import annotations

import argparse
import getpass
import html
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

LIST_URL = "https://leetcode.com/api/problems/algorithms/"
GRAPHQL_URL = "https://leetcode.com/graphql"
DEFAULT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def user_agent():
    # Cloudflare ties its clearance cookie to the browser that earned it.
    return os.environ.get("LEETCODE_USER_AGENT", "").strip() or DEFAULT_UA
DETAIL_QUERY = """
query getQuestionDetail($titleSlug: String!) {
  question(titleSlug: $titleSlug) {
    questionId
    questionFrontendId
    title
    content
    difficulty
    stats
    likes
    codeDefinition
    codeSnippets { lang langSlug code }
    sampleTestCase
    exampleTestcases
    metaData
    hints
    topicTags { name }
    isPaidOnly
  }
}
""".strip()
LEVELS = {1: "Easy", 2: "Medium", 3: "Hard"}
DESIGN_SOURCES = [
    "https://raw.githubusercontent.com/donnemartin/system-design-primer/master/README.md",
    "https://raw.githubusercontent.com/checkcheckzz/system-design-interview/master/README.md",
]
ALGO_REPOS = [
    ("TheAlgorithms/Python", "python", ".py"),
    ("TheAlgorithms/JavaScript", "javascript", ".js"),
]


class AuthRequired(Exception):
    pass


def is_leetcode(url):
    """True only when the URL's host is leetcode.com or one of its subdomains."""
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    return host == "leetcode.com" or host.endswith(".leetcode.com")


def paths():
    here = Path(__file__).resolve().parent
    if here.name == "prep" and here.parent.name == "scripts":
        root = here.parents[1]
        plugin = root / "data" / "plugins" / "prep"
    else:
        plugin = here
    return plugin / "bank", plugin / "curated"


def slugify(text):
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug or "question"


def cookie_headers():
    raw = os.environ.get("LEETCODE_COOKIE", "").strip()
    session = os.environ.get("LEETCODE_SESSION", "").strip()
    csrf = os.environ.get("LEETCODE_CSRF", "").strip()
    if raw:
        found_session = re.search(r"LEETCODE_SESSION=(.+?)(?:;|$)", raw)
        found_csrf = re.search(r"csrftoken=(.+?)(?:;|$)", raw)
        if found_session:
            session = found_session.group(1).strip()
        if found_csrf:
            csrf = found_csrf.group(1).strip()
        cookie = raw if "LEETCODE_SESSION=" in raw else "LEETCODE_SESSION=%s;csrftoken=%s;" % (session, csrf)
    elif session:
        cookie = "LEETCODE_SESSION=%s;csrftoken=%s;" % (session, csrf)
    else:
        return {}
    headers = {"Cookie": cookie, "X-Requested-With": "XMLHttpRequest"}
    if csrf:
        headers["X-CSRFToken"] = csrf
    return headers


def base_headers(referer=None, leetcode=False):
    headers = {
        "User-Agent": user_agent(),
        "Accept": "application/json,text/plain,*/*",
    }
    # The LeetCode cookie must not be attached to GitHub or other hosts.
    if leetcode:
        headers["Origin"] = "https://leetcode.com"
        headers["Referer"] = referer or "https://leetcode.com/"
        headers.update(cookie_headers())
    return headers


def request(url, data=None, referer=None, timeout=40):
    payload = None if data is None else json.dumps(data).encode("utf-8")
    headers = base_headers(referer, leetcode=is_leetcode(url))
    if payload is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=payload, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            status = getattr(resp, "status", 200)
    except urllib.error.HTTPError as exc:
        body = exc.read()
        status = exc.code
    text = body.decode("utf-8", "replace")
    if is_leetcode(url) and (status in (401, 403) or "Just a moment" in text or "cf-browser-verification" in text):
        raise AuthRequired("LeetCode returned %s" % status)
    if status >= 400:
        raise RuntimeError("HTTP %s from %s" % (status, url))
    return text


def request_json(url, data=None, referer=None, retries=4, timeout=40):
    delay = 1.0
    last = None
    for _ in range(retries):
        try:
            text = request(url, data=data, referer=referer, timeout=timeout)
            return json.loads(text)
        except AuthRequired:
            raise
        except Exception as exc:
            last = exc
            time.sleep(delay)
            delay = min(delay * 2, 20)
    raise RuntimeError(str(last))


class ToMarkdown(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0
        self.pre = False
        self.href = None

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        attrs = dict(attrs)
        if tag in ("script", "style"):
            self.skip += 1
        elif tag == "pre":
            self.pre = True
            self.parts.append("\n```\n")
        elif tag in ("p", "div", "h1", "h2", "h3", "h4", "br", "tr", "section"):
            self.parts.append("\n")
        elif tag == "li":
            self.parts.append("\n- ")
        elif tag == "code" and not self.pre:
            self.parts.append("`")
        elif tag in ("strong", "b"):
            self.parts.append("**")
        elif tag in ("em", "i"):
            self.parts.append("*")
        elif tag == "sup":
            self.parts.append("^")
        elif tag == "a":
            self.href = attrs.get("href")

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in ("script", "style"):
            self.skip = max(0, self.skip - 1)
        elif tag == "pre":
            self.pre = False
            self.parts.append("\n```\n")
        elif tag == "code" and not self.pre:
            self.parts.append("`")
        elif tag in ("strong", "b"):
            self.parts.append("**")
        elif tag in ("em", "i"):
            self.parts.append("*")
        elif tag == "a" and self.href:
            self.parts.append(" (%s)" % self.href)
            self.href = None

    def handle_data(self, data):
        if self.skip:
            return
        self.parts.append(data)


def html_to_md(content):
    if not content:
        return ""
    parser = ToMarkdown()
    parser.feed(content)
    parser.close()
    text = html.unescape("".join(parser.parts))
    text = text.replace("\r\n", "\n")
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() + "\n"


def remember_template(found, lang, code):
    lang = (lang or "").lower()
    if lang == "python":
        lang = "python3"
    if lang not in ("python3", "javascript", "java") or not code or lang in found:
        return
    found[lang] = code


def templates_from(question):
    found = {}
    for snip in question.get("codeSnippets") or []:
        remember_template(found, snip.get("langSlug"), snip.get("code") or "")
    raw = question.get("codeDefinition")
    if raw and ("python3" not in found or "javascript" not in found or "java" not in found):
        try:
            data = json.loads(raw) if isinstance(raw, str) else raw
        except json.JSONDecodeError:
            data = []
        for item in data or []:
            lang = item.get("value") or item.get("langSlug") or ""
            code = item.get("defaultCode") or item.get("text") or item.get("code") or ""
            remember_template(found, lang, code)
    return found


def meta_from(raw):
    if not raw:
        return None
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            return None
    if not isinstance(raw, dict) or not raw.get("name"):
        return None
    return {
        "name": raw.get("name"),
        "params": raw.get("params") or [],
        "return": raw.get("return"),
    }


def load_curated(curated):
    rounds = {}
    for name in ("coding", "design", "debug", "explain"):
        path = curated / ("%s.json" % name)
        if not path.exists():
            rounds[name] = []
            continue
        rounds[name] = json.loads(path.read_text(encoding="utf-8"))
        for question in rounds[name]:
            question["round"] = name
    return rounds


def fetch_problem_list():
    payload = request_json(LIST_URL)
    problems = []
    for pair in payload.get("stat_status_pairs") or []:
        stat = pair.get("stat") or {}
        if stat.get("question__hide") or pair.get("paid_only"):
            continue
        level = LEVELS.get((pair.get("difficulty") or {}).get("level"))
        if not level:
            continue
        problems.append({
            "slug": stat.get("question__title_slug"),
            "title": stat.get("question__title"),
            "frontend_id": stat.get("frontend_question_id"),
            "question_id": stat.get("question_id"),
            "difficulty": level,
            "acs": stat.get("total_acs") or 0,
            "submitted": stat.get("total_submitted") or 0,
        })
    return problems


def select_problems(problems, per_difficulty):
    chosen = []
    for level in ("Easy", "Medium", "Hard"):
        group = [item for item in problems if item["difficulty"] == level]
        group.sort(key=lambda item: item["acs"], reverse=True)
        chosen.extend(group[:per_difficulty])
    return chosen


def fetch_detail(problem, cache_dir, throttle):
    cache = cache_dir / ("%s.json" % problem["slug"])
    if cache.exists():
        return json.loads(cache.read_text(encoding="utf-8"))
    referer = "https://leetcode.com/problems/%s/description/" % problem["slug"]
    payload = request_json(GRAPHQL_URL, {
        "operationName": "getQuestionDetail",
        "query": DETAIL_QUERY,
        "variables": {"titleSlug": problem["slug"]},
    }, referer=referer)
    question = ((payload or {}).get("data") or {}).get("question")
    if not question:
        raise AuthRequired("empty question for %s" % problem["slug"])
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(question), encoding="utf-8")
    if throttle:
        time.sleep(throttle)
    return question


def coding_record(problem, detail):
    examples = detail.get("exampleTestcases") or detail.get("sampleTestCase") or ""
    return {
        "round": "coding",
        "slug": problem["slug"],
        "title": "%s. %s" % (problem["frontend_id"], detail.get("title") or problem["title"]),
        "difficulty": problem["difficulty"],
        "frontend_id": problem["frontend_id"],
        "content_md": html_to_md(detail.get("content") or ""),
        "hints": detail.get("hints") or [],
        "examples": examples,
        "meta": meta_from(detail.get("metaData")),
        "templates": templates_from(detail),
        "tags": [tag.get("name") for tag in (detail.get("topicTags") or []) if tag.get("name")],
        "source": "leetcode",
        "likes": detail.get("likes") or 0,
        "acs": problem["acs"],
    }


def fetch_leetcode(bank, per_difficulty, throttle, resume):
    print("Fetching LeetCode problem list...")
    selected = select_problems(fetch_problem_list(), per_difficulty)
    print("Selected %d problems." % len(selected))
    cache_dir = bank / ".cache"
    records = []
    for index, problem in enumerate(selected, 1):
        dest = bank / "coding" / ("%s.json" % problem["slug"])
        if resume and dest.exists():
            records.append(json.loads(dest.read_text(encoding="utf-8")))
            print("[%d/%d] %s (cached)" % (index, len(selected), problem["slug"]))
            continue
        print("[%d/%d] %s" % (index, len(selected), problem["slug"]))
        detail = fetch_detail(problem, cache_dir, throttle)
        records.append(coding_record(problem, detail))
    return records


def fetch_text(url):
    try:
        return request(url, timeout=40)
    except AuthRequired:
        raise
    except Exception as exc:
        print("Skip %s (%s)" % (url, exc))
        return ""


def clean_design_line(line):
    """Turn one README line into a question title, or return an empty string."""
    if "|" in line:  # a table row: the title is the first cell
        cells = [cell for cell in line.split("|") if cell.strip()]
        line = cells[0] if cells else ""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", line)  # [text](url) -> text
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[`|*_]", "", text)
    text = re.sub(r"^\s*#+\s*", "", text)
    text = re.sub(r"^\s*(?:[-+]|\d+[.)])\s*", "", text)
    text = re.sub(r"\s+", " ", text).strip(" .:-")
    return text


def design_from_readmes(curated_questions):
    found = list(curated_questions)
    seen = {slugify(item.get("title") or item.get("slug") or "") for item in found}
    pattern = re.compile(r"^(?:design\b.+|how (?:would|do) you design\b.+)", re.I)
    for url in DESIGN_SOURCES:
        print("Reading %s" % url)
        text = fetch_text(url)
        for line in text.splitlines():
            clean = clean_design_line(line)
            if len(clean) < 24 or len(clean) > 160 or not pattern.match(clean):
                continue
            slug = slugify(clean)
            if slug in seen:
                continue
            seen.add(slug)
            found.append({
                "round": "design",
                "slug": slug,
                "title": clean[:1].upper() + clean[1:],
                "difficulty": "Medium",
                "content_md": "# %s\n\nWalk through requirements, API, data model, scale, and what fails.\n" % clean,
                "followups": [],
                "source": url,
            })
    return found


def github_tree(repo):
    for branch in ("master", "main"):
        url = "https://api.github.com/repos/%s/git/trees/%s?recursive=1" % (repo, branch)
        try:
            payload = request_json(url, timeout=60)
        except Exception as exc:
            print("Tree %s@%s failed (%s)" % (repo, branch, exc))
            continue
        if payload.get("tree"):
            return branch, payload["tree"]
    return None, []


def strip_docs(source, language):
    points = []
    if language == "python":
        match = re.match(r'\s*("""|\'\'\')([\s\S]*?)\1', source)
        if match:
            points = [line.strip(" -") for line in match.group(2).splitlines() if line.strip()][:6]
            source = source[match.end():]
        source = re.sub(r'"""[\s\S]*?"""', "", source)
        source = re.sub(r"'''[\s\S]*?'''", "", source)
    else:
        match = re.match(r"\s*/\*\*([\s\S]*?)\*/", source)
        if match:
            points = [re.sub(r"^\s*\*\s?", "", line).strip() for line in match.group(1).splitlines() if line.strip()][:6]
            source = source[match.end():]
        source = re.sub(r"/\*[\s\S]*?\*/", "", source)
    source = source.strip() + "\n"
    return source, [point for point in points if point]


def fetch_explain(limit):
    records = []
    rng = random.Random(21)
    per_repo = max(1, limit // 2)
    for repo, language, ext in ALGO_REPOS:
        branch, tree = github_tree(repo)
        if not tree:
            continue
        files = [
            item["path"] for item in tree
            if item.get("type") == "blob"
            and item["path"].endswith(ext)
            and "/__init__" not in item["path"]
            and "test" not in item["path"].lower()
            and item["path"].count("/") >= 1
        ]
        rng.shuffle(files)
        taken = 0
        for path in files:
            if taken >= per_repo:
                break
            raw_url = "https://raw.githubusercontent.com/%s/%s/%s" % (repo, branch, path)
            try:
                source = request(raw_url, timeout=30)
            except Exception as exc:
                print("Skip %s (%s)" % (path, exc))
                continue
            if len(source) < 80 or len(source) > 8000:
                continue
            code, points = strip_docs(source, language)
            if len(code) < 40:
                continue
            title = Path(path).stem.replace("_", " ").replace("-", " ")
            slug = slugify(language + "-" + path)
            records.append({
                "round": "explain",
                "slug": slug[:80],
                "title": "Explain: " + title,
                "difficulty": "Medium",
                "language": language,
                "code": code,
                "expected_points": points or ["What it computes.", "Time and space.", "Edge cases."],
                "content_md": "Read the code and explain it. The interesting parts were stripped on purpose.\n",
                "source": raw_url,
            })
            taken += 1
            print("Explain %s" % path)
            time.sleep(0.2)
    return records


def chat_json(prompt, model):
    key = os.environ.get("OPENAI_API_KEY", "")
    base = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
    if not key:
        raise RuntimeError("OPENAI_API_KEY is not set")
    body = json.dumps({
        "model": model,
        "temperature": 0.3,
        "messages": [
            {"role": "system", "content": "Reply with JSON only."},
            {"role": "user", "content": prompt},
        ],
    }).encode("utf-8")
    req = urllib.request.Request(
        base + "/chat/completions",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    return payload["choices"][0]["message"]["content"]


def extract_json(text):
    match = re.search(r"\{[\s\S]*\}", text)
    if not match:
        raise RuntimeError("model did not return JSON")
    return json.loads(match.group(0))


def generate_debug(coding, count, model):
    records = []
    for question in coding[:count]:
        prompt = (
            "Plant 1 to 3 subtle bugs in a correct solution for this problem. "
            "Return JSON {buggy_code, correct_code, failing_test, language}. "
            "language is python or javascript. failing_test is a short input that fails.\n\n"
            + question.get("content_md", "")[:2500]
        )
        try:
            data = extract_json(chat_json(prompt, model))
        except Exception as exc:
            print("Debug generation skipped for %s (%s)" % (question.get("slug"), exc))
            continue
        records.append({
            "round": "debug",
            "slug": question["slug"] + "-bug",
            "title": "Debug: " + question.get("title", question["slug"]),
            "difficulty": question.get("difficulty") or "Medium",
            "language": "javascript" if data.get("language") == "javascript" else "python",
            "buggy_code": data.get("buggy_code") or "",
            "correct_code": data.get("correct_code") or "",
            "failing_test": data.get("failing_test") or "",
            "content_md": "The starter code is wrong. Find the bug. A failing case is listed below.\n",
            "source": "generated",
        })
        print("Debug %s" % question["slug"])
    return records


def generate_quiz(count, model, existing):
    prompt = (
        "Write %d multiple-choice interview questions on data structures, algorithms, "
        "and system design. Return JSON {\"questions\":[{\"id\",\"topic\",\"q\",\"choices\",\"answer\",\"explain\"}]}. "
        "choices has 4 strings. answer is the correct index starting at 1. Keep each explain to one sentence."
        % count
    )
    data = extract_json(chat_json(prompt, model))
    questions = data.get("questions") or []
    seen = {item.get("id") for item in existing}
    for item in questions:
        if item.get("id") in seen:
            continue
        if not item.get("q") or not item.get("choices"):
            continue
        existing.append(item)
    return existing


def index_row(question):
    return {
        "slug": question["slug"],
        "title": question.get("title"),
        "difficulty": question.get("difficulty"),
        "id": question.get("frontend_id"),
    }


def write_round(bank, name, questions):
    folder = bank / name
    folder.mkdir(parents=True, exist_ok=True)
    for question in questions:
        path = folder / ("%s.json" % question["slug"])
        path.write_text(json.dumps(question, indent=2), encoding="utf-8")
    return [index_row(question) for question in questions]


def merge_by_slug(primary, extra):
    seen = {item["slug"] for item in primary}
    merged = list(primary)
    for item in extra:
        if item.get("slug") and item["slug"] not in seen:
            seen.add(item["slug"])
            merged.append(item)
    return merged


def main():
    parser = argparse.ArgumentParser(description="Build the prep question bank.")
    parser.add_argument("--per-difficulty", type=int, default=150)
    parser.add_argument("--throttle", type=float, default=0.4)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--login", action="store_true", help="Prompt for a LeetCode cookie.")
    parser.add_argument("--cookie-stdin", action="store_true", help="Read the LeetCode cookie from the first line of stdin.")
    parser.add_argument("--skip-leetcode", action="store_true")
    parser.add_argument("--skip-design", action="store_true")
    parser.add_argument("--skip-explain", action="store_true")
    parser.add_argument("--explain", type=int, default=40)
    parser.add_argument("--gen-debug", type=int, default=0)
    parser.add_argument("--gen-quiz", type=int, default=0)
    parser.add_argument("--model", default=os.environ.get("OPENAI_MODEL", "gpt-4o-mini"))
    parser.add_argument("--out", default="", help="Directory for the generated bank. Defaults to the plugin bank.")
    args = parser.parse_args()

    if args.cookie_stdin and not os.environ.get("LEETCODE_COOKIE"):
        os.environ["LEETCODE_COOKIE"] = sys.stdin.readline().strip()
    if args.login and not os.environ.get("LEETCODE_COOKIE"):
        os.environ["LEETCODE_COOKIE"] = getpass.getpass("Paste LeetCode Cookie: ")

    default_bank, curated = paths()
    bank = Path(args.out) if args.out else default_bank
    bank.mkdir(parents=True, exist_ok=True)
    bundled = load_curated(curated)

    try:
        coding = [] if args.skip_leetcode else fetch_leetcode(bank, args.per_difficulty, args.throttle, args.resume)
    except AuthRequired as exc:
        print("AUTH_REQUIRED %s" % exc)
        return 3
    except Exception as exc:
        print("LeetCode fetch failed: %s" % exc, file=sys.stderr)
        return 1

    coding = merge_by_slug(coding, bundled.get("coding") or [])
    design = bundled.get("design") or []
    if not args.skip_design:
        try:
            design = design_from_readmes(design)
        except AuthRequired:
            print("AUTH_REQUIRED")
            return 3
    debug = list(bundled.get("debug") or [])
    explain = list(bundled.get("explain") or [])
    if not args.skip_explain and args.explain > 0:
        explain = merge_by_slug(fetch_explain(args.explain), explain)
    if args.gen_debug:
        debug = merge_by_slug(generate_debug(coding, args.gen_debug, args.model), debug)
    quiz_path = curated / "quiz.json"
    quiz = json.loads(quiz_path.read_text(encoding="utf-8")) if quiz_path.exists() else []
    if args.gen_quiz:
        quiz = generate_quiz(args.gen_quiz, args.model, quiz)

    index = {
        "coding": write_round(bank, "coding", coding),
        "design": write_round(bank, "design", design),
        "debug": write_round(bank, "debug", debug),
        "explain": write_round(bank, "explain", explain),
    }
    (bank / "index.json").write_text(json.dumps(index, indent=2), encoding="utf-8")
    (bank / "quiz.json").write_text(json.dumps(quiz, indent=2), encoding="utf-8")
    print("Wrote %s" % (bank / "index.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
