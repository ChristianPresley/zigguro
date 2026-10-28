-- Key-to-photon samples (the perf.key_to_photon_ns counter), worst first.
SELECT c.ts, c.value / 1e6 AS key_to_photon_ms
FROM counter c
JOIN counter_track t ON c.track_id = t.id
WHERE t.name = 'perf.key_to_photon_ns'
ORDER BY c.value DESC
LIMIT 50;
