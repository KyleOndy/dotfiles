"""Test fixture for generating images with different aspect ratios.

This module provides utilities for creating test JPEG images with various
aspect ratios (portrait, landscape, square, ultra-wide, ultra-tall) for
testing layout and visual polish.
"""

from pathlib import Path
from tempfile import mkdtemp

from PIL import Image, ImageDraw, ImageFont


def generate_test_images(output_dir: Path | None = None) -> Path:
    """Generate test images with different aspect ratios.

    Creates JPEG images in various aspect ratios with distinct colors
    and labels for easy identification during visual testing.

    Args:
        output_dir: Directory to save images. If None, creates temp directory.

    Returns:
        Path to the directory containing generated images.
    """
    if output_dir is None:
        output_dir = Path(mkdtemp(prefix="visual_test_images_"))
    else:
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

    # Define test images: (filename, width, height, color, label)
    test_images = [
        ("portrait_1.jpg", 2000, 3000, (255, 100, 100), "Portrait 2:3"),
        ("portrait_2.jpg", 2000, 3000, (100, 255, 100), "Portrait 2:3"),
        ("landscape_1.jpg", 3000, 2000, (100, 100, 255), "Landscape 3:2"),
        ("landscape_2.jpg", 3000, 2000, (255, 255, 100), "Landscape 3:2"),
        ("square_1.jpg", 2000, 2000, (255, 100, 255), "Square 1:1"),
        ("square_2.jpg", 2000, 2000, (100, 255, 255), "Square 1:1"),
        ("ultrawide.jpg", 4000, 1500, (200, 150, 100), "Ultra-wide 8:3"),
        ("ultratall.jpg", 1500, 4000, (150, 100, 200), "Ultra-tall 3:8"),
        ("panorama.jpg", 6000, 1500, (180, 180, 100), "Panorama 4:1"),
    ]

    for filename, width, height, color, label in test_images:
        # Create colored image
        img = Image.new("RGB", (width, height), color)

        # Add label text
        draw = ImageDraw.Draw(img)

        # Try to use a reasonable font size (20% of smaller dimension)
        font_size = int(min(width, height) * 0.2)

        try:
            # Try to load a TrueType font (may not be available in all environments)
            font = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", font_size
            )
        except OSError:
            # Fall back to default font
            font = ImageFont.load_default()

        # Calculate text position (center of image)
        # Use textbbox to get text dimensions
        bbox = draw.textbbox((0, 0), label, font=font)
        text_width = bbox[2] - bbox[0]
        text_height = bbox[3] - bbox[1]

        x = (width - text_width) // 2
        y = (height - text_height) // 2

        # Draw text with black outline for visibility
        outline_width = max(2, font_size // 30)
        for dx in range(-outline_width, outline_width + 1):
            for dy in range(-outline_width, outline_width + 1):
                if dx != 0 or dy != 0:
                    draw.text((x + dx, y + dy), label, font=font, fill=(0, 0, 0))

        # Draw white text on top
        draw.text((x, y), label, font=font, fill=(255, 255, 255))

        # Save as JPEG
        img.save(output_dir / filename, "JPEG", quality=95)

    return output_dir


if __name__ == "__main__":
    # Generate images when run directly
    output_dir = generate_test_images()
    print(f"Generated test images in: {output_dir}")
    print(f"Run: uv run winnow {output_dir}")
