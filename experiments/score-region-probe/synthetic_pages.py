"""Generate tiny artificial score pages; no image files or private data needed."""

from dataclasses import dataclass

from region_evaluation import Box


@dataclass(frozen=True)
class Staff:
    left: int
    top: int
    right: int
    gap: int = 8
    slope: int = 0
    broken: bool = False

    def reference(self):
        # One-pixel line endpoints plus modest padding around the six strings.
        return Box(self.left - 3, self.top + min(0, self.slope) - 3,
                   self.right + 3, self.top + max(0, self.slope) + 5 * self.gap + 4)


def make_page(width, height, staffs=(), *, five_line_decoy=False, grid_decoy=False):
    """Return an 8-bit gray buffer and TAB reference boxes for synthetic tests.

    `right` is exclusive. Slope is the integer y change across a whole staff.
    The five-line and grid decoys are not included in the TAB references.
    """
    if width < 40 or height < 40:
        raise ValueError("Page too small")
    pixels = bytearray([255]) * (width * height)

    def pixel(x, y):
        if 0 <= x < width and 0 <= y < height:
            pixels[y * width + x] = 0

    def line(left, right, top, gap, count, slope=0, broken=False):
        if right <= left or gap <= 0:
            raise ValueError("Invalid staff")
        for x in range(left, right):
            if broken and (x - left) % 31 in (14, 15):
                continue
            y = top + round(slope * (x - left) / max(1, right - left - 1))
            for index in range(count):
                pixel(x, y + index * gap)

    references = []
    for staff in staffs:
        reference = staff.reference()
        if reference.left < 0 or reference.top < 0 or reference.right > width or reference.bottom > height:
            raise ValueError("Staff reference must fit in the page")
        line(staff.left, staff.right, staff.top, staff.gap, 6, staff.slope, staff.broken)
        references.append(reference)
    if five_line_decoy:
        line(8, width - 8, 8, 5, 5)
    if grid_decoy:
        # A fretboard-like six-line grid is deliberately not a TAB label.
        top = height - 40
        line(8, width - 8, top, 5, 6)
        for x in range(8, width - 8, 10):
            for y in range(top, top + 26):
                pixel(x, y)
    return pixels, tuple(references)
