use serde::{Deserialize, Serialize};

/// 2D point in display-local coordinates (top-left origin, y down).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    #[inline]
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    #[inline]
    pub fn distance_to(self, other: Self) -> f64 {
        (self.x - other.x).hypot(self.y - other.y)
    }
}

/// 2D size.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

impl Size {
    pub const ZERO: Self = Self {
        width: 0.0,
        height: 0.0,
    };

    #[inline]
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

/// 2D velocity / delta vector.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Vector {
    pub dx: f64,
    pub dy: f64,
}

impl Vector {
    pub const ZERO: Self = Self { dx: 0.0, dy: 0.0 };

    #[inline]
    pub const fn new(dx: f64, dy: f64) -> Self {
        Self { dx, dy }
    }

    #[inline]
    pub fn length(self) -> f64 {
        self.dx.hypot(self.dy)
    }
}

/// Axis-aligned rectangle (top-left origin, y down).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const ZERO: Self = Self {
        x: 0.0,
        y: 0.0,
        width: 0.0,
        height: 0.0,
    };

    #[inline]
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    #[inline]
    pub fn from_origin_size(origin: Point, size: Size) -> Self {
        Self {
            x: origin.x,
            y: origin.y,
            width: size.width,
            height: size.height,
        }
    }

    #[inline]
    pub fn origin(self) -> Point {
        Point::new(self.x, self.y)
    }

    #[inline]
    pub fn size(self) -> Size {
        Size::new(self.width, self.height)
    }

    #[inline]
    pub fn min_x(self) -> f64 {
        self.x
    }

    #[inline]
    pub fn min_y(self) -> f64 {
        self.y
    }

    #[inline]
    pub fn max_x(self) -> f64 {
        self.x + self.width
    }

    #[inline]
    pub fn max_y(self) -> f64 {
        self.y + self.height
    }

    #[inline]
    pub fn mid_x(self) -> f64 {
        self.x + self.width * 0.5
    }

    #[inline]
    pub fn mid_y(self) -> f64 {
        self.y + self.height * 0.5
    }

    #[inline]
    pub fn inset_by(self, dx: f64, dy: f64) -> Self {
        Self {
            x: self.x + dx,
            y: self.y + dy,
            width: self.width - dx * 2.0,
            height: self.height - dy * 2.0,
        }
    }

    #[inline]
    pub fn contains(self, p: Point) -> bool {
        p.x >= self.min_x() && p.x <= self.max_x() && p.y >= self.min_y() && p.y <= self.max_y()
    }

    /// Physical Win32 display rectangles exclude their right and bottom edges.
    pub fn contains_pixel(self, p: Point) -> bool {
        p.x >= self.min_x() && p.x < self.max_x() && p.y >= self.min_y() && p.y < self.max_y()
    }

    #[inline]
    pub fn union(self, other: Self) -> Self {
        let min_x = self.min_x().min(other.min_x());
        let min_y = self.min_y().min(other.min_y());
        let max_x = self.max_x().max(other.max_x());
        let max_y = self.max_y().max(other.max_y());
        Self::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }
}

/// Linear sRGB color with alpha in `[0.0, 1.0]`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ColorRgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl ColorRgba {
    #[inline]
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }

    #[inline]
    pub const fn with_alpha(self, a: f32) -> Self {
        Self { a, ..self }
    }

    #[inline]
    pub fn blended_with_white(self, fraction: f32) -> Self {
        let f = fraction.clamp(0.0, 1.0);
        Self {
            r: self.r + (1.0 - self.r) * f,
            g: self.g + (1.0 - self.g) * f,
            b: self.b + (1.0 - self.b) * f,
            a: self.a,
        }
    }
}
