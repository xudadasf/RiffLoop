"""Compare independent, human-labelled TAB notes without reading score files.

Positions must use the same normalised x anchor in each reference/prediction
pair. Matching is confined to one crop and does not evaluate duration, playing
technique, region detection or whether that anchor is appropriate for OCR.
"""

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class Note:
    x: float
    string: int | None
    fret: int | None


@dataclass(frozen=True)
class Result:
    reference_count: int
    prediction_count: int
    localized: int
    correct: int
    unresolved: int

    @property
    def missing(self):
        return self.reference_count - self.localized

    @property
    def extra(self):
        return self.prediction_count - self.localized

    @property
    def localized_but_incorrect(self):
        # Separate maximum matchings are used for localization and correctness;
        # this is a count difference, not an assignment of errors to notes.
        return self.localized - self.correct

    @property
    def precision(self):
        return self.correct / self.prediction_count if self.prediction_count else None

    @property
    def recall(self):
        return self.correct / self.reference_count if self.reference_count else None


def _validate(note, *, reference):
    if not isinstance(note, Note):
        raise ValueError("Expected Note")
    if isinstance(note.x, bool) or not isinstance(note.x, (int, float)) or not math.isfinite(note.x) or not 0 <= note.x <= 1:
        raise ValueError("Note position must be finite and normalized to [0, 1]")
    for value, minimum, maximum in ((note.string, 1, 6), (note.fret, 0, 36)):
        if value is None and not reference:
            continue
        if type(value) is not int or not minimum <= value <= maximum:
            raise ValueError("Invalid or missing string/fret")


def _match_count(references, predictions, eligible):
    # One-to-one maximum cardinality, so duplicates cannot count twice and
    # candidate iteration order cannot reduce the number of matches.
    owners = {}

    def assign(reference_index, seen):
        for prediction_index, prediction in enumerate(predictions):
            if prediction_index in seen or not eligible(references[reference_index], prediction):
                continue
            seen.add(prediction_index)
            if prediction_index not in owners or assign(owners[prediction_index], seen):
                owners[prediction_index] = reference_index
                return True
        return False

    for index in range(len(references)):
        assign(index, set())
    return len(owners)


def _validate_tolerance(max_x_error):
    if isinstance(max_x_error, bool) or not isinstance(max_x_error, (int, float)) or not math.isfinite(max_x_error) or not 0 <= max_x_error <= 1:
        raise ValueError("max_x_error must be finite and in [0, 1]")


def assess(references, predictions, *, max_x_error):
    """Score one crop; callers must not combine notes from different crops.

    A complete match requires x distance <= max_x_error and identical string
    and fret. Localization ignores string/fret, so a wrong value is not hidden
    by treating it only as a missing note. A predicted unknown counts in the
    denominator and can never be a complete match. Rates with no denominator
    are None. Thresholds must be agreed before comparing model versions.
    """
    _validate_tolerance(max_x_error)
    references, predictions = tuple(references), tuple(predictions)
    # Keep matching bounded and avoid recursive path exhaustion on corrupt data.
    if len(references) > 512 or len(predictions) > 512:
        raise ValueError("At most 512 notes per crop")
    for note in references:
        _validate(note, reference=True)
    for note in predictions:
        _validate(note, reference=False)
    close = lambda ref, pred: abs(ref.x - pred.x) <= max_x_error
    localized = _match_count(references, predictions, close)
    correct = _match_count(references, predictions,
                           lambda ref, pred: close(ref, pred) and ref.string == pred.string and ref.fret == pred.fret)
    return Result(len(references), len(predictions), localized, correct,
                  sum(note.string is None or note.fret is None for note in predictions))


def assess_crops(crops, *, max_x_error):
    """Aggregate counts only after matching each (reference, prediction) crop."""
    _validate_tolerance(max_x_error)
    results = [assess(reference, prediction, max_x_error=max_x_error)
               for reference, prediction in crops]
    return Result(*(sum(getattr(result, field) for result in results)
                    for field in ('reference_count', 'prediction_count', 'localized', 'correct', 'unresolved')))
