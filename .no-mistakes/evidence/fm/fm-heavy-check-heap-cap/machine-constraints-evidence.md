# Evidence: machine constraints in generated ship/scout briefs

## 1. Section placement (headings order in each generated brief)

### mc-no-mistakes
3:# Task
10:# Herdr lifecycle declaration - NOT ENABLED
15:# Setup
25:# Machine constraints
33:# Rules
74:# Firstmate instruction inbox
79:# Waiting work and the released slot
85:# Project memory
92:# Definition of done

### mc-direct-PR
3:# Task
10:# Herdr lifecycle declaration - NOT ENABLED
15:# Setup
24:# Machine constraints
32:# Rules
71:# Firstmate instruction inbox
76:# Waiting work and the released slot
82:# Project memory
89:# Definition of done

### mc-local-only
3:# Task
10:# Herdr lifecycle declaration - NOT ENABLED
15:# Setup
24:# Machine constraints
32:# Rules
71:# Firstmate instruction inbox
76:# Waiting work and the released slot
82:# Project memory
89:# Definition of done

### mc-scout
3:# Task
10:# Herdr lifecycle declaration - NOT ENABLED
15:# Setup
21:# Machine constraints
29:# Rules
64:# Firstmate instruction inbox
69:# Waiting work and the released slot
75:# Definition of done

## 2. Section presence by scaffold kind
mc-no-mistakes: 1
mc-direct-PR: 1
mc-local-only: 1
mc-scout: 1
mc-charter (secondmate, deliberately out of scope): 0

## 3. Regression: pre-fix c29a5ca script renders no section
mc-prefix-no-mistakes: 0
mc-prefix-scout: 0

## 4. Rendered section (mc-no-mistakes)
# Machine constraints
The primary build host is small (about 3.8 GB RAM, 2 cores, no swap) and heavy node steps there have starved other lanes before; this fleet also runs on larger hosts, so check your own host's memory and cores before choosing limits.
- On a memory-tight host, cap the heap of every node step: `NODE_OPTIONS="--max-old-space-size=2048"` (1536 when the machine is loaded), never 4096 or larger; a host with memory to spare sets its own capacity.
- Run heavy checks - lint, tsc, test suites, builds - strictly sequentially per workspace; never two at once.
- If this home provides the machine-wide build token, take it before anything that starts a node toolchain or runs longer than a few seconds: pnpm install, prisma generate, every build, every test suite, dev servers; wait while it is held. Otherwise run one heavy step at a time.
- Stop a dev server as soon as the step that needed it ends.
The bullets above are the authoritative rules for your work; the full machine rules and their history are in /tmp/fm-brief-evidence/home/data/captain.md and /tmp/fm-brief-evidence/home/data/learnings.md where this home provides them.

