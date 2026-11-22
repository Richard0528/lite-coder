"use strict";

class ListNode {
  constructor(val, next) {
    this.val = val === undefined ? 0 : val;
    this.next = next === undefined ? null : next;
  }
}

class TreeNode {
  constructor(val, left, right) {
    this.val = val === undefined ? 0 : val;
    this.left = left === undefined ? null : left;
    this.right = right === undefined ? null : right;
  }
}

function listToLinked(values) {
  const dummy = new ListNode();
  let cur = dummy;
  for (const value of values || []) {
    cur.next = new ListNode(value);
    cur = cur.next;
  }
  return dummy.next;
}

function listToTree(values) {
  if (!values || values.length === 0 || values[0] === null) return null;
  const root = new TreeNode(values[0]);
  const queue = [root];
  let index = 1;
  while (queue.length && index < values.length) {
    const node = queue.shift();
    if (index < values.length && values[index] !== null) {
      node.left = new TreeNode(values[index]);
      queue.push(node.left);
    }
    index += 1;
    if (index < values.length && values[index] !== null) {
      node.right = new TreeNode(values[index]);
      queue.push(node.right);
    }
    index += 1;
  }
  return root;
}

function showNode(node) {
  const out = [];
  const seen = new Set();
  while (node && !seen.has(node)) {
    seen.add(node);
    out.push(node.val);
    node = node.next;
    if (out.length > 64) break;
  }
  return "[" + out.join(",") + "]";
}

function showTree(node) {
  const out = [];
  const queue = [node];
  while (queue.length) {
    const current = queue.shift();
    if (!current) {
      out.push("null");
      continue;
    }
    out.push(String(current.val));
    queue.push(current.left);
    queue.push(current.right);
  }
  while (out.length && out[out.length - 1] === "null") out.pop();
  return "[" + out.join(",") + "]";
}

function show(value) {
  if (value instanceof ListNode) return showNode(value);
  if (value instanceof TreeNode) return showTree(value);
  try {
    return JSON.stringify(value);
  } catch (err) {
    return String(value);
  }
}

class MinHeap {
  constructor(compare) {
    this.data = [];
    this.compare = compare || ((a, b) => a - b);
  }
  push(value) {
    this.data.push(value);
    this._up(this.data.length - 1);
  }
  pop() {
    if (this.data.length === 0) return undefined;
    const top = this.data[0];
    const last = this.data.pop();
    if (this.data.length) {
      this.data[0] = last;
      this._down(0);
    }
    return top;
  }
  peek() { return this.data[0]; }
  get size() { return this.data.length; }
  _up(index) {
    while (index > 0) {
      const parent = (index - 1) >> 1;
      if (this.compare(this.data[index], this.data[parent]) >= 0) break;
      [this.data[index], this.data[parent]] = [this.data[parent], this.data[index]];
      index = parent;
    }
  }
  _down(index) {
    const n = this.data.length;
    while (true) {
      let smallest = index;
      const left = index * 2 + 1;
      const right = left + 1;
      if (left < n && this.compare(this.data[left], this.data[smallest]) < 0) smallest = left;
      if (right < n && this.compare(this.data[right], this.data[smallest]) < 0) smallest = right;
      if (smallest === index) break;
      [this.data[index], this.data[smallest]] = [this.data[smallest], this.data[index]];
      index = smallest;
    }
  }
}

class MaxHeap extends MinHeap {
  constructor(compare) {
    super(compare || ((a, b) => b - a));
  }
}

class Deque {
  constructor() { this.data = []; }
  push(value) { this.data.push(value); }
  pushLeft(value) { this.data.unshift(value); }
  pop() { return this.data.pop(); }
  popLeft() { return this.data.shift(); }
  peek() { return this.data[this.data.length - 1]; }
  peekLeft() { return this.data[0]; }
  get size() { return this.data.length; }
}

function assert(cond, message) {
  if (!cond) throw new Error(message || "assertion failed");
}

function parseLiteral(text) {
  return JSON.parse(text.trim());
}

function convert(value, typeName) {
  const type = String(typeName || "").replace(/\s+/g, "");
  if (type === "ListNode" || type === "ListNode*") return listToLinked(value || []);
  if (type === "TreeNode" || type === "TreeNode*") return listToTree(value);
  return value;
}

function runExamples(spec) {
  const name = spec.name || "solve";
  const params = spec.params || [];
  const lines = String(spec.examples || "").split(/\r?\n/).filter((line) => line.trim() !== "");
  const width = Math.max(params.length, 1);
  if (!lines.length) {
    console.log("No examples.");
    return;
  }
  let index = 0;
  let example = 1;
  while (index < lines.length) {
    const chunk = lines.slice(index, index + width);
    if (chunk.length < width) {
      console.log("Example " + example + ": not enough lines for " + width + " parameters");
      break;
    }
    let args;
    try {
      args = chunk.map((line, i) => convert(parseLiteral(line), params[i] && params[i].type));
    } catch (err) {
      console.log("Example " + example + ": could not parse input (" + err.message + ")");
      index += width;
      example += 1;
      continue;
    }
    let fn = typeof global.__prepLookup === "function" ? global.__prepLookup(name) : global[name];
    if (typeof fn !== "function") {
      console.log("Define Solution." + name + " or a function named " + name + " to run examples.");
      return;
    }
    try {
      console.log("Example " + example + ": " + show(fn(...args)));
    } catch (err) {
      console.log("Example " + example + ":");
      console.error(err && err.stack ? err.stack : String(err));
    }
    index += width;
    example += 1;
  }
}

Object.assign(global, {
  ListNode, TreeNode, listToLinked, listToTree,
  MinHeap, MaxHeap, Deque, assert, runExamples, show,
});
