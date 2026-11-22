"""Run a prep solution with a small standard-library prelude.

Tracebacks use the solution filename. When PREP_SPEC is set, each example
from the question is parsed and passed to the solution function.
"""
import bisect
import collections
import functools
import heapq
import itertools
import json
import math
import os
import random
import re
import string
import sys
from collections import Counter, defaultdict, deque
from typing import List, Dict, Optional, Tuple, Set


class ListNode:
    def __init__(self, val=0, next=None):
        self.val = val
        self.next = next

    def __repr__(self):
        out = []
        seen = set()
        node = self
        while node is not None and id(node) not in seen:
            seen.add(id(node))
            out.append(repr(node.val))
            node = node.next
            if len(out) > 64:
                out.append("...")
                break
        return "[" + ",".join(out) + "]"


class TreeNode:
    def __init__(self, val=0, left=None, right=None):
        self.val = val
        self.left = left
        self.right = right

    def __repr__(self):
        out = []
        queue = [self]
        while queue:
            node = queue.pop(0)
            if node is None:
                out.append("null")
                continue
            out.append(repr(node.val))
            queue.append(node.left)
            queue.append(node.right)
        while out and out[-1] == "null":
            out.pop()
        return "[" + ",".join(out) + "]"


def list_to_linked(values):
    dummy = ListNode()
    cur = dummy
    for value in values or []:
        cur.next = ListNode(value)
        cur = cur.next
    return dummy.next


def list_to_tree(values):
    if not values or values[0] is None:
        return None
    root = TreeNode(values[0])
    queue = [root]
    index = 1
    while queue and index < len(values):
        node = queue.pop(0)
        if index < len(values) and values[index] is not None:
            node.left = TreeNode(values[index])
            queue.append(node.left)
        index += 1
        if index < len(values) and values[index] is not None:
            node.right = TreeNode(values[index])
            queue.append(node.right)
        index += 1
    return root


def parse_literal(text):
    # Example lines are JSON, so quoted text such as "nullable" stays intact.
    return json.loads(text.strip())


def convert(value, type_name):
    type_name = (type_name or "").replace(" ", "")
    if type_name in ("ListNode", "ListNode*"):
        return list_to_linked(value or [])
    if type_name in ("TreeNode", "TreeNode*"):
        return list_to_tree(value)
    return value


def show(value):
    if isinstance(value, (ListNode, TreeNode)):
        return repr(value)
    try:
        return json.dumps(value)
    except TypeError:
        return repr(value)


PRELUDE = {
    "ListNode": ListNode,
    "TreeNode": TreeNode,
    "list_to_linked": list_to_linked,
    "list_to_tree": list_to_tree,
    "Counter": Counter,
    "defaultdict": defaultdict,
    "deque": deque,
    "bisect": bisect,
    "heapq": heapq,
    "itertools": itertools,
    "functools": functools,
    "math": math,
    "random": random,
    "re": re,
    "string": string,
    "collections": collections,
    "List": List,
    "Dict": Dict,
    "Optional": Optional,
    "Tuple": Tuple,
    "Set": Set,
}


def run_examples(globs, spec):
    name = spec.get("name") or "solve"
    params = spec.get("params") or []
    lines = [line for line in (spec.get("examples") or "").splitlines() if line.strip() != ""]
    width = max(len(params), 1)
    if not lines:
        print("No examples.")
        return
    index = 0
    case = 1
    while index < len(lines):
        chunk = lines[index:index + width]
        if len(chunk) < width:
            print("Example %d: not enough lines for %d parameters" % (case, width))
            break
        try:
            args = [convert(parse_literal(chunk[i]), params[i].get("type")) for i in range(width)]
        except Exception as exc:
            print("Example %d: could not parse input (%s)" % (case, exc))
            index += width
            case += 1
            continue
        fn = None
        solution = globs.get("Solution")
        if isinstance(solution, type):
            try:
                obj = solution()
                fn = getattr(obj, name, None)
            except Exception as exc:
                print("Example %d: Solution() failed: %s" % (case, exc))
                return
        if fn is None:
            fn = globs.get(name)
        if not callable(fn):
            print("Define Solution.%s or a function named %s to run examples." % (name, name))
            return
        try:
            result = fn(*args)
            print("Example %d: %s" % (case, show(result)))
        except Exception:
            print("Example %d:" % case)
            traceback_lines = sys.exc_info()
            import traceback
            traceback.print_exc()
        index += width
        case += 1


def main():
    if len(sys.argv) < 2:
        print("usage: run.py solution.py", file=sys.stderr)
        return 2
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as handle:
        source = handle.read()
    globs = {"__name__": "__main__"}
    globs.update(PRELUDE)
    try:
        exec(compile(source, os.path.basename(path), "exec"), globs, globs)
    except SystemExit:
        raise
    except Exception:
        import traceback
        traceback.print_exc()
        return 1
    spec_path = os.environ.get("PREP_SPEC")
    if spec_path:
        with open(spec_path, "r", encoding="utf-8") as handle:
            spec = json.load(handle)
        try:
            run_examples(globs, spec)
        except Exception:
            import traceback
            traceback.print_exc()
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
