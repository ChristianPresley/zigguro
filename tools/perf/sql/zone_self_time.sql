-- Self time per zone name: each slice's duration minus its direct
-- children's, summed by name.
SELECT s.name,
       COUNT(*) AS calls,
       SUM(s.dur - IFNULL(c.child_dur, 0)) / 1e6 AS self_ms,
       SUM(s.dur) / 1e6 AS total_ms
FROM slice s
LEFT JOIN (
  SELECT parent_id, SUM(dur) AS child_dur
  FROM slice
  WHERE parent_id IS NOT NULL
  GROUP BY parent_id
) c ON c.parent_id = s.id
GROUP BY s.name
ORDER BY self_ms DESC
LIMIT 50;
