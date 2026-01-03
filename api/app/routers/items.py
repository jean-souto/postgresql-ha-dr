"""
Items CRUD endpoints - Demo resource for testing database operations.
"""

from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, Query

from ..db import get_connection
from ..models import Item, ItemCreate, ItemUpdate

router = APIRouter(prefix="/items", tags=["Items"])


# =============================================================================
# Ensure table exists
# =============================================================================

async def ensure_table_exists() -> None:
    """Create items table if it doesn't exist."""
    async with get_connection() as conn:
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS items (
                id SERIAL PRIMARY KEY,
                name VARCHAR(255) NOT NULL,
                description TEXT,
                price DECIMAL(10, 2) NOT NULL,
                is_active BOOLEAN DEFAULT TRUE,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
                updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
            )
        """)
        # Create index for common queries
        await conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_items_is_active ON items(is_active)
        """)


# =============================================================================
# CRUD Endpoints
# =============================================================================

@router.post("", response_model=Item, status_code=201)
async def create_item(item: ItemCreate) -> Item:
    """Create a new item."""
    await ensure_table_exists()

    async with get_connection() as conn:
        row = await conn.fetchrow(
            """
            INSERT INTO items (name, description, price, is_active, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $5)
            RETURNING id, name, description, price, is_active, created_at, updated_at
            """,
            item.name,
            item.description,
            item.price,
            item.is_active,
            datetime.now(UTC),
        )

    return Item(**dict(row))


@router.get("", response_model=list[Item])
async def list_items(
    skip: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=1000),
    active_only: bool = Query(False),
) -> list[Item]:
    """List all items with pagination."""
    await ensure_table_exists()

    async with get_connection() as conn:
        if active_only:
            rows = await conn.fetch(
                """
                SELECT id, name, description, price, is_active, created_at, updated_at
                FROM items
                WHERE is_active = TRUE
                ORDER BY id
                OFFSET $1 LIMIT $2
                """,
                skip,
                limit,
            )
        else:
            rows = await conn.fetch(
                """
                SELECT id, name, description, price, is_active, created_at, updated_at
                FROM items
                ORDER BY id
                OFFSET $1 LIMIT $2
                """,
                skip,
                limit,
            )

    return [Item(**dict(row)) for row in rows]


@router.get("/{item_id}", response_model=Item)
async def get_item(item_id: int) -> Item:
    """Get a specific item by ID."""
    await ensure_table_exists()

    async with get_connection() as conn:
        row = await conn.fetchrow(
            """
            SELECT id, name, description, price, is_active, created_at, updated_at
            FROM items
            WHERE id = $1
            """,
            item_id,
        )

    if row is None:
        raise HTTPException(status_code=404, detail=f"Item {item_id} not found")

    return Item(**dict(row))


@router.put("/{item_id}", response_model=Item)
async def update_item(item_id: int, item: ItemUpdate) -> Item:
    """Update an existing item."""
    await ensure_table_exists()

    # Build dynamic update query
    update_fields = []
    values = []
    param_count = 1

    if item.name is not None:
        update_fields.append(f"name = ${param_count}")
        values.append(item.name)
        param_count += 1

    if item.description is not None:
        update_fields.append(f"description = ${param_count}")
        values.append(item.description)
        param_count += 1

    if item.price is not None:
        update_fields.append(f"price = ${param_count}")
        values.append(item.price)
        param_count += 1

    if item.is_active is not None:
        update_fields.append(f"is_active = ${param_count}")
        values.append(item.is_active)
        param_count += 1

    if not update_fields:
        raise HTTPException(status_code=400, detail="No fields to update")

    update_fields.append(f"updated_at = ${param_count}")
    values.append(datetime.now(UTC))
    param_count += 1

    values.append(item_id)

    query = f"""
        UPDATE items
        SET {', '.join(update_fields)}
        WHERE id = ${param_count}
        RETURNING id, name, description, price, is_active, created_at, updated_at
    """

    async with get_connection() as conn:
        row = await conn.fetchrow(query, *values)

    if row is None:
        raise HTTPException(status_code=404, detail=f"Item {item_id} not found")

    return Item(**dict(row))


@router.delete("/{item_id}", status_code=204)
async def delete_item(item_id: int) -> None:
    """Delete an item."""
    await ensure_table_exists()

    async with get_connection() as conn:
        result = await conn.execute(
            "DELETE FROM items WHERE id = $1",
            item_id,
        )

    # Check if any row was deleted
    if result == "DELETE 0":
        raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
