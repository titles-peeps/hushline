"""update default brand color

Revision ID: b2785f3b20f0
Revises: f32aa741ddc4
Create Date: 2025-09-24 00:00:00.000000

"""

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = "b2785f3b20f0"
down_revision = "f32aa741ddc4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        sa.text(
            """
        UPDATE organization_settings
        SET value = to_jsonb('#000000'::text)
        WHERE key = 'brand_primary_color' AND value = to_jsonb('#7d25c1'::text)
        """
        )
    )


def downgrade() -> None:
    op.execute(
        sa.text(
            """
        UPDATE organization_settings
        SET value = to_jsonb('#7d25c1'::text)
        WHERE key = 'brand_primary_color' AND value = to_jsonb('#000000'::text)
        """
        )
    )
