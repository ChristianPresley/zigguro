-- The 20 slowest frames: gui.frame slices by duration, with their thread.
-- trace_processor_shell -q tools/perf/sql/slowest_frames.sql trace.pftrace
SELECT s.ts, s.dur / 1e6 AS dur_ms, t.name AS thread
FROM slice s
JOIN thread_track tt ON s.track_id = tt.id
JOIN thread t USING (utid)
WHERE s.name = 'gui.frame'
ORDER BY s.dur DESC
LIMIT 20;
