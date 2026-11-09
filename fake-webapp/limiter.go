package main

import (
	"sync"
	"time"
)

// Clock allows injecting time in tests.
type Clock func() time.Time

// bucket is a token-bucket limiter shared by all clients.
type bucket struct {
	mu     sync.Mutex
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
	now    Clock
}

func newBucket(rps, burst float64, now Clock) *bucket {
	burst = max(burst, 1)
	return &bucket{rate: rps, burst: burst, tokens: burst, last: now(), now: now}
}

func (b *bucket) Allow() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	t := b.now()
	if d := t.Sub(b.last).Seconds(); d > 0 {
		b.tokens = min(b.burst, b.tokens+d*b.rate)
		b.last = t
	}
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

const maxTrackedIPs = 50000

type ipBucket struct {
	tokens float64
	last   time.Time
}

// ipLimiter is a token bucket per client IP with bounded memory.
type ipLimiter struct {
	mu    sync.Mutex
	rate  float64
	burst float64
	now   Clock
	m     map[string]*ipBucket
	max   int
}

func newIPLimiter(rate, burst float64, now Clock) *ipLimiter {
	return &ipLimiter{rate: rate, burst: max(burst, 1), now: now, m: map[string]*ipBucket{}, max: maxTrackedIPs}
}

// Allow takes a token for ip. If none is left, retry is the time until one is.
func (l *ipLimiter) Allow(ip string) (ok bool, retry time.Duration) {
	if len(ip) > 64 {
		ip = ip[:64]
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	t := l.now()
	b, exists := l.m[ip]
	if !exists {
		if len(l.m) >= l.max {
			l.makeRoomLocked(t)
		}
		b = &ipBucket{tokens: l.burst, last: t}
		l.m[ip] = b
	} else if d := t.Sub(b.last).Seconds(); d > 0 {
		b.tokens = min(l.burst, b.tokens+d*l.rate)
		b.last = t
	}
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	wait := time.Duration((1 - b.tokens) / l.rate * float64(time.Second))
	return false, max(wait, time.Second/10)
}

func (l *ipLimiter) idleLocked(b *ipBucket, t time.Time) bool {
	return b.tokens+t.Sub(b.last).Seconds()*l.rate >= l.burst
}

// makeRoomLocked drops idle buckets, then (if still full) an arbitrary tenth.
func (l *ipLimiter) makeRoomLocked(t time.Time) {
	for k, b := range l.m {
		if l.idleLocked(b, t) {
			delete(l.m, k)
		}
	}
	n := len(l.m) - l.max + max(l.max/10, 1)
	for k := range l.m {
		if n <= 0 {
			break
		}
		delete(l.m, k)
		n--
	}
}

// Cleanup evicts buckets that have fully refilled (idle clients).
func (l *ipLimiter) Cleanup() {
	l.mu.Lock()
	defer l.mu.Unlock()
	t := l.now()
	for k, b := range l.m {
		if l.idleLocked(b, t) {
			delete(l.m, k)
		}
	}
}

const (
	loginWindow      = 60 * time.Second
	loginMaxAttempts = 3 // the 3rd attempt within the window is blocked
	maxTrackedUsers  = 100000
	maxUsernameKey   = 256
)

// loginThrottle tracks per-username attempts in a sliding window.
type loginThrottle struct {
	mu       sync.Mutex
	now      Clock
	attempts map[string][]time.Time
	order    []string // insertion order for eviction (may contain stale keys)
	maxKeys  int
}

func newLoginThrottle(now Clock) *loginThrottle {
	return &loginThrottle{now: now, attempts: map[string][]time.Time{}, maxKeys: maxTrackedUsers}
}

// Attempt records an attempt and reports whether it is allowed. If not,
// retryAfter is the time until the oldest attempt leaves the window.
func (l *loginThrottle) Attempt(key string) (ok bool, retryAfter time.Duration) {
	if len(key) > maxUsernameKey {
		key = key[:maxUsernameKey]
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	t := l.now()
	cut := t.Add(-loginWindow)
	ts, exists := l.attempts[key]
	i := 0
	for i < len(ts) && !ts[i].After(cut) {
		i++
	}
	ts = ts[i:]
	if !exists {
		if len(l.attempts) >= l.maxKeys {
			l.evictLocked()
		}
		l.order = append(l.order, key)
	}
	if len(ts) >= loginMaxAttempts-1 {
		// Blocked. Keep recording (bounded) so hammering extends the block.
		if len(ts) < loginMaxAttempts+5 {
			ts = append(ts, t)
		}
		l.attempts[key] = ts
		return false, max(ts[0].Add(loginWindow).Sub(t), time.Second)
	}
	l.attempts[key] = append(ts, t)
	return true, 0
}

func (l *loginThrottle) evictLocked() {
	n := max(l.maxKeys/10, 1)
	removed, idx := 0, 0
	for idx < len(l.order) && removed < n {
		if _, ok := l.attempts[l.order[idx]]; ok {
			delete(l.attempts, l.order[idx])
			removed++
		}
		idx++
	}
	l.order = append([]string(nil), l.order[idx:]...)
}

// Cleanup removes entries with no attempts inside the window.
func (l *loginThrottle) Cleanup() {
	l.mu.Lock()
	defer l.mu.Unlock()
	cut := l.now().Add(-loginWindow)
	for k, ts := range l.attempts {
		if len(ts) == 0 || !ts[len(ts)-1].After(cut) {
			delete(l.attempts, k)
		}
	}
	live := make([]string, 0, len(l.attempts))
	seen := make(map[string]struct{}, len(l.attempts))
	for _, k := range l.order {
		if _, ok := l.attempts[k]; !ok {
			continue
		}
		if _, dup := seen[k]; dup {
			continue
		}
		seen[k] = struct{}{}
		live = append(live, k)
	}
	l.order = live
}
