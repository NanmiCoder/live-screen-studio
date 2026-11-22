use std::f64::consts::PI;

use serde::{Deserialize, Serialize};

use crate::core::geometry::{ColorRgba, Point, Rect, Size};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InkStyle {
    Marker,
    Neon,
    Highlighter,
    Arrow,
    Dashed,
}

impl InkStyle {
    pub fn title(self) -> &'static str {
        match self {
            Self::Marker => "马克笔",
            Self::Neon => "霓虹",
            Self::Highlighter => "荧光笔",
            Self::Arrow => "箭头",
            Self::Dashed => "流动虚线",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HighlightKind {
    Box,
    Underline,
    Fill,
    Spotlight,
}

impl HighlightKind {
    pub fn title(self) -> &'static str {
        match self {
            Self::Box => "框住这一行",
            Self::Underline => "给这一行划线",
            Self::Fill => "荧光笔涂这一行",
            Self::Spotlight => "聚光灯",
        }
    }
}

/// Clusters OCR word/line segments into the single text line under `point`.
pub struct TextLines;

impl TextLines {
    pub fn line(point: Point, segments: &[Rect]) -> Option<Rect> {
        let mut seed_idx: Option<usize> = None;
        let mut best_score = f64::INFINITY;
        for (i, &seg) in segments.iter().enumerate() {
            if point.y >= seg.min_y() - seg.height * 0.8
                && point.y <= seg.max_y() + seg.height * 0.8
                && Self::horizontal_gap(point, seg) <= seg.height * 4.0
            {
                let s = Self::score(point, seg);
                if s < best_score {
                    best_score = s;
                    seed_idx = Some(i);
                }
            }
        }
        let seed = segments[seed_idx?];
        let mut line = seed;
        let mut rest: Vec<Rect> = segments
            .iter()
            .copied()
            .filter(|&r| {
                r != seed
                    && Self::vertical_overlap(r, seed) >= 0.5 * r.height.min(seed.height)
                    && r.height.min(seed.height) >= 0.7 * r.height.max(seed.height)
            })
            .collect();

        let mut grew = true;
        while grew {
            grew = false;
            let mut idx = rest.len();
            while idx > 0 {
                idx -= 1;
                let r = rest[idx];
                let gap = (r.min_x() - line.max_x())
                    .max(line.min_x() - r.max_x())
                    .max(0.0);
                if gap <= seed.height * 1.5 {
                    line = line.union(r);
                    rest.remove(idx);
                    grew = true;
                }
            }
        }
        Some(line)
    }

    #[inline]
    fn score(p: Point, r: Rect) -> f64 {
        let vertical = (r.min_y() - p.y).max(p.y - r.max_y()).max(0.0);
        vertical * 1000.0 + Self::horizontal_gap(p, r)
    }

    #[inline]
    fn horizontal_gap(p: Point, r: Rect) -> f64 {
        (r.min_x() - p.x).max(p.x - r.max_x()).max(0.0)
    }

    #[inline]
    fn vertical_overlap(a: Rect, b: Rect) -> f64 {
        (a.max_y().min(b.max_y()) - a.min_y().max(b.min_y())).max(0.0)
    }
}

pub struct ArrowHead;

impl ArrowHead {
    pub const DEFAULT_ANGLE: f64 = PI / 6.5;

    pub fn barbs(points: &[Point], length: f64, angle: f64) -> Option<(Point, Point)> {
        let &tip = points.last()?;
        if points.len() < 2 {
            return None;
        }
        let mut back = points[points.len() - 2];
        for &p in points[..points.len() - 1].iter().rev() {
            back = p;
            if tip.distance_to(p) >= length {
                break;
            }
        }
        let dx = tip.x - back.x;
        let dy = tip.y - back.y;
        let distance = dx.hypot(dy);
        if distance < length * 0.25 {
            return None;
        }
        let heading = dy.atan2(dx);
        let barb = |side: f64| -> Point {
            let a = heading + PI + side * angle;
            Point::new(tip.x + a.cos() * length, tip.y + a.sin() * length)
        };
        Some((barb(1.0), barb(-1.0)))
    }
}

#[derive(Debug, Clone, Copy)]
pub struct InkLook {
    pub style: InkStyle,
    pub color: ColorRgba,
    /// On screen, in display points.
    pub width: f64,
}

#[derive(Debug, Clone)]
pub enum AnnotationItem {
    Stroke {
        look: InkLook,
        /// Content units per screen point (`1.0 / zoom` at creation).
        unit: f64,
        points: Vec<Point>,
        created_at: f64,
    },
    Highlight {
        kind: HighlightKind,
        line: Rect,
        display: Size,
        look: InkLook,
        unit: f64,
        created_at: f64,
    },
}

impl AnnotationItem {
    pub fn new_stroke(start: Point, look: InkLook, zoom: f64, now: f64) -> Self {
        Self::Stroke {
            look,
            unit: 1.0 / zoom.max(1.0),
            points: vec![start],
            created_at: now,
        }
    }

    pub fn new_highlight(
        kind: HighlightKind,
        line: Rect,
        display: Size,
        look: InkLook,
        zoom: f64,
        now: f64,
    ) -> Self {
        Self::Highlight {
            kind,
            line,
            display,
            look,
            unit: 1.0 / zoom.max(1.0),
            created_at: now,
        }
    }

    pub fn is_spotlight(&self) -> bool {
        matches!(
            self,
            Self::Highlight {
                kind: HighlightKind::Spotlight,
                ..
            }
        )
    }

    pub fn extend(&mut self, p: Point, straight: bool) -> bool {
        let Self::Stroke { unit, points, .. } = self else {
            return false;
        };
        let Some(&last) = points.last() else {
            return false;
        };
        if straight {
            if points.len() == 2 && last == p {
                return false;
            }
            points.truncate(1);
            points.push(p);
            return true;
        }
        if p.distance_to(last) < 0.75 * *unit {
            return false;
        }
        points.push(p);
        true
    }
}
