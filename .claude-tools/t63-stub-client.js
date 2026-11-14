// TEMPORARY stub client for the T6.3 headless check (copied into site/mirror/_t63/, deleted after).
let n = 0;
const id = () => "x" + ++n;
const P = {
  self: true, can_add: ["general"],
  goals: [
    { id: "g1", dimension: "work", dimension_title: "Work and education", category: "general", private: false, title: "Get a CDL", detail: null, stage: 4, hope_by: "2027-06-01", status: "active", achieved_on: null, set_by_role: "self" },
    { id: "g2", dimension: "housing", dimension_title: "Housing", category: "general", private: false, title: "Riverwest list", detail: null, stage: null, hope_by: null, status: "active", achieved_on: null, set_by_role: "coordinator" },
    { id: "g3", dimension: "mental_health", dimension_title: "How I feel inside", category: "mental_health", private: true, title: "Find a counselor", detail: null, stage: 2, hope_by: null, status: "paused", achieved_on: null, set_by_role: "self" }],
  actions: [
    { id: "s1", goal_id: "g1", need_id: null, need_title: null, private: false, title: "Get the handbook", who: "me", helper: null, due_on: "2026-12-01", status: "open", added_by_role: "self" },
    { id: "s2", goal_id: null, need_id: "n1", need_title: "Dentist", private: true, title: "Call the clinic", who: "helper", helper: "My sister", due_on: null, status: "open", added_by_role: "self" }],
  milestones: [{ id: "m1", goal_id: null, dimension: null, dimension_title: null, private: false, title: "Got my state ID", detail: null, achieved_on: "2026-11-01", automatic: false, verified: true, added_by_role: "self" }],
  needs: [{ id: "n1", title: "Dentist", private: true }],
};
window.__calls = [];
export async function requireArea() { return { memberships: [] }; }
export async function rpc(name, a = {}) {
  window.__calls.push([name, JSON.parse(JSON.stringify(a))]);
  const p = a.p || {};
  if (name === "mirror_plan") return JSON.parse(JSON.stringify(P));
  if (name === "mirror_goal_save") {
    let g = P.goals.find((x) => x.id === a.p_id);
    if (!g) { g = { id: id(), set_by_role: "self", dimension_title: "Area" }; P.goals.push(g); }
    Object.assign(g, { dimension: p.dimension, title: p.title, detail: p.detail, stage: p.stage ? Number(p.stage) : null, hope_by: p.hope_by || null, status: p.status,
      achieved_on: p.status === "achieved" ? "2026-11-13" : null });
    if (p.status === "achieved" && !P.milestones.some((m) => m.goal_id === g.id)) P.milestones.unshift({ id: id(), goal_id: g.id, title: g.title, achieved_on: "2026-11-13", automatic: true, verified: false, added_by_role: "self" });
    return g;
  }
  if (name === "mirror_action_save") {
    let s = P.actions.find((x) => x.id === a.p_id);
    if (!s) { s = { id: id(), added_by_role: "self" }; P.actions.push(s); }
    Object.assign(s, { title: p.title, goal_id: p.goal_id || null, need_id: p.need_id || null, who: p.who, helper: p.who === "helper" ? p.helper : null, due_on: p.due_on || null, status: p.status });
    return s;
  }
  if (name === "mirror_milestone_save") {
    let m = P.milestones.find((x) => x.id === a.p_id);
    if (!m) { m = { id: id(), added_by_role: "self", automatic: false, verified: false }; P.milestones.push(m); }
    Object.assign(m, { title: p.title, achieved_on: p.achieved_on, goal_id: p.goal_id || null, dimension: p.dimension || null, detail: p.detail });
    return m;
  }
  if (name === "mirror_plan_delete") {
    const k = { goal: "goals", action: "actions", milestone: "milestones" }[a.p_kind];
    P[k] = P[k].filter((x) => x.id !== a.p_id);
    if (a.p_kind === "goal") P.actions = P.actions.filter((s) => s.goal_id !== a.p_id);
    return true;
  }
  throw new Error("unexpected " + name);
}
