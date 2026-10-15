# NN — Component name

**Status:** Draft | Review | Accepted
**Owner:** 
**Last updated:** YYYY-MM-DD
**Language / runtime:** 

One-paragraph summary: what this component is, what it is responsible for, and what it is explicitly not responsible for.

## 1. Responsibilities

Bulleted. Each line is something this component, and only this component, owns.

## 2. Non-goals

What this component deliberately does not do, and which component does it instead.

## 3. Interfaces

### 3.1 Inbound

Who calls this component, over what protocol, with what contract. Link to the API specification where the contract is defined there.

### 3.2 Outbound

What this component calls, and what it assumes about those dependencies (latency, availability, consistency).

## 4. State

What this component stores, where, and with what durability. Distinguish source-of-truth state from caches and derived state.

## 5. Core flows

One subsection per significant flow. Sequence diagrams in Mermaid. Each flow must say what happens on failure at every step.

## 6. Failure modes

Table: failure, detection, impact, recovery. Include the boring ones (disk full, dependency slow) not only the interesting ones.

## 7. Performance and capacity

Latency budget, throughput targets, resource ceilings. Numbers, not adjectives. Say which are requirements and which are estimates.

## 8. Security

Trust boundaries this component sits on, what it authenticates, what it must never log.

## 9. Observability

Metrics, logs, and traces this component emits. Name the three signals an on-call engineer looks at first.

## 10. Testing

How this component is tested in isolation and in integration. What test fixtures exist.

## 11. Alternatives considered

Short. Only the close calls.

## 12. Open questions

| Question | Owner | Needed by |
|----------|-------|-----------|
