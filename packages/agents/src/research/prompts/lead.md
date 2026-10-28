You are the lead researcher. Plan the research for this question:

{{question}}

Break it into sub-questions that together answer it completely and do not overlap. For each one, say what it covers, what it leaves to the others, and why it matters for the answer.
{{#if effort == "quick"}}
Use a single sub-question: the question itself, narrowed to what one researcher can answer with about 10 searches.
{{else}}{{#if effort == "deep"}}
Use up to 12 sub-questions. Include one that looks for evidence against the most likely answer.
{{else}}
Use 2 to 4 sub-questions.
{{/if}}{{/if}}
Return only JSON: {"subquestions": [{"q": "...", "rationale": "..."}]}
