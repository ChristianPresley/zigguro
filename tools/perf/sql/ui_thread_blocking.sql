-- Top-level work on the UI thread longer than 4 ms (a frame at 240 Hz).
SELECT s.ts, s.dur / 1e6 AS dur_ms, s.name
FROM slice s
JOIN thread_track tt ON s.track_id = tt.id
JOIN thread t USING (utid)
WHERE t.name = 'ui' AND s.depth = 0 AND s.dur > 4e6
ORDER BY s.dur DESC;
