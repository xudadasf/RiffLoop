"""Evaluate generated six-line region proposals, independently of the app.

Boxes use half-open pixel coordinates (left, top, right, bottom). Results are
diagnostics, not an OCR accuracy score or evidence about real photographs.
"""

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class Box:
    left: float
    top: float
    right: float
    bottom: float

    def __post_init__(self):
        coordinates = (self.left, self.top, self.right, self.bottom)
        if not all(math.isfinite(v) for v in coordinates) or self.right <= self.left or self.bottom <= self.top:
            raise ValueError("Box must have finite coordinates and positive area")

    @property
    def area(self):
        return (self.right - self.left) * (self.bottom - self.top)

    def overlap_area(self, other):
        return (max(0, min(self.right, other.right) - max(self.left, other.left)) *
                max(0, min(self.bottom, other.bottom) - max(self.top, other.top)))


@dataclass(frozen=True)
class RegionAssessment:
    # Indices refer to the input lists, allowing the caller to inspect examples.
    matched: tuple[tuple[int, int], ...]  # (reference, proposal)
    missing: tuple[int, ...]
    truncated: tuple[int, ...]
    fragmented: tuple[int, ...]
    merged: tuple[int, ...]
    oversized: tuple[int, ...]
    false_positive: tuple[int, ...]
    duplicate: tuple[int, ...]


def assess(references, proposals, *, complete=0.98, relevant=0.15, max_area_ratio=2.0):
    """Match full coverage one-to-one; additionally report distinct failure modes.

    A proposal is a merge if it covers at least ``relevant`` of two different
    references. A single-reference proposal larger than ``max_area_ratio``
    times the reference is oversized. Neither can count as a correct match.
    Area is a practical proxy for unrelated material, not a semantic guarantee.
    A reference without a
    complete eligible match is missing if no proposal reaches ``relevant``.
    It is truncated if no single proposal fully covers it, and fragmented if
    two or more partial proposals reach it. A complete but merged proposal is
    a merge rather than a truncation. A proposal with no relevant reference is a false
    positive; an eligible one covering only an already-matched reference is a duplicate.
    Diagnostics may overlap: e.g. a fragmented reference is also truncated.

    Thresholds are experimental and defined against reference area, not IoU.
    This permits reasonable margins around a staff. They are not a substitute
    for manually verifying page content or the exact start/end of the notation.
    """
    if not (0 < relevant < complete <= 1):
        raise ValueError("Expected 0 < relevant < complete <= 1")
    if not math.isfinite(max_area_ratio) or max_area_ratio < 1:
        raise ValueError("Expected finite max_area_ratio >= 1")
    references, proposals = tuple(references), tuple(proposals)
    coverage = [[proposal.overlap_area(reference) / reference.area
                 for proposal in proposals] for reference in references]
    touched = [[p for p in range(len(proposals)) if coverage[r][p] >= relevant]
               for r in range(len(references))]
    merged = {p for p in range(len(proposals))
              if sum(coverage[r][p] >= relevant for r in range(len(references))) >= 2}
    oversized = {p for p in range(len(proposals)) if p not in merged
                 and any(coverage[r][p] >= relevant and
                         proposals[p].area > references[r].area * max_area_ratio
                         for r in range(len(references)))}

    # Maximum-cardinality one-to-one matching. Ineligible merged proposals are
    # excluded, even if they enclose several complete reference rectangles.
    proposal_owner = {}

    def match(reference, seen):
        for proposal in range(len(proposals)):
            if proposal in merged or proposal in oversized or proposal in seen or coverage[reference][proposal] < complete:
                continue
            seen.add(proposal)
            if proposal not in proposal_owner or match(proposal_owner[proposal], seen):
                proposal_owner[proposal] = reference
                return True
        return False

    for reference in range(len(references)):
        match(reference, set())
    matched = tuple(sorted((reference, proposal) for proposal, reference in proposal_owner.items()))
    matched_references = {reference for reference, _ in matched}
    matched_proposals = set(proposal_owner)
    missing = tuple(r for r in range(len(references)) if r not in matched_references and not touched[r])
    truncated = tuple(r for r in range(len(references)) if r not in matched_references and touched[r]
                      and not any(coverage[r][p] >= complete for p in touched[r]))
    fragmented = tuple(r for r in truncated if len(touched[r]) >= 2)
    false_positive = tuple(p for p in range(len(proposals))
                           if not any(coverage[r][p] >= relevant for r in range(len(references))))
    duplicate = tuple(p for p in range(len(proposals)) if p not in merged and p not in oversized and p not in matched_proposals
                      and any(coverage[r][p] >= complete and r in matched_references for r in range(len(references))))
    return RegionAssessment(matched, missing, truncated, fragmented, tuple(sorted(merged)),
                            tuple(sorted(oversized)), false_positive, duplicate)
