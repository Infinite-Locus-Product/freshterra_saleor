"""Tests for the FreshTerra `ft_warehouse_id` allocation hint.

The FreshTerra backend stamps the target Saleor Warehouse GID under the
``ft_warehouse_id`` key on the checkout shipping-address metadata (copied onto
the order shipping address at checkout completion). When present, stock
reservation and allocation must be constrained to that single warehouse; when
absent, the default multi-warehouse behavior is preserved.
"""

import datetime
import uuid

import graphene
import pytest
from django.utils import timezone

from ...core.exceptions import InsufficientStock
from ...order.fetch import OrderLineInfo
from ...plugins.manager import get_plugins_manager
from ..management import (
    FT_WAREHOUSE_METADATA_KEY,
    allocate_stocks,
    resolve_ft_warehouse_pk,
)
from ..models import Allocation, Reservation, Stock, Warehouse
from ..reservations import reserve_stocks

COUNTRY_CODE = "US"
RESERVATION_LENGTH = 5


def _warehouse_gid(warehouse) -> str:
    return graphene.Node.to_global_id("Warehouse", warehouse.pk)


def _stamp_order_shipping_hint(order, warehouse) -> None:
    address = order.shipping_address
    address.metadata = {FT_WAREHOUSE_METADATA_KEY: _warehouse_gid(warehouse)}
    address.save(update_fields=["metadata"])


# --- pure helper unit tests (no DB) -----------------------------------------


def test_resolve_ft_warehouse_pk_valid_gid():
    warehouse_pk = str(uuid.uuid4())
    gid = graphene.Node.to_global_id("Warehouse", warehouse_pk)

    assert resolve_ft_warehouse_pk({FT_WAREHOUSE_METADATA_KEY: gid}) == warehouse_pk


@pytest.mark.parametrize(
    "metadata",
    [
        None,
        {},
        {"other": "value"},
        {FT_WAREHOUSE_METADATA_KEY: ""},
        {FT_WAREHOUSE_METADATA_KEY: "not-a-valid-gid"},
    ],
)
def test_resolve_ft_warehouse_pk_absent_or_malformed_returns_none(metadata):
    assert resolve_ft_warehouse_pk(metadata) is None


def test_resolve_ft_warehouse_pk_wrong_type_returns_none():
    # A GID for a non-Warehouse node must be ignored.
    gid = graphene.Node.to_global_id("Product", str(uuid.uuid4()))

    assert resolve_ft_warehouse_pk({FT_WAREHOUSE_METADATA_KEY: gid}) is None


# --- allocate_stocks --------------------------------------------------------


def test_allocate_stocks_constrained_to_ft_warehouse_hint(
    order_line, variant_with_many_stocks, channel_USD
):
    # given: variant stocked in two warehouses (qty 4 and qty 3), both serving US
    variant = variant_with_many_stocks
    stock_high = variant.stocks.get(quantity=4)  # default strategy would pick this
    stock_low = variant.stocks.get(quantity=3)
    order_line.quantity = 3
    order_line.save(update_fields=["quantity"])
    # stamp the hint pointing at the *lower* stock warehouse
    _stamp_order_shipping_hint(order_line.order, stock_low.warehouse)

    line_data = OrderLineInfo(line=order_line, variant=variant, quantity=3)

    # when
    allocate_stocks(
        [line_data],
        COUNTRY_CODE,
        channel_USD,
        manager=get_plugins_manager(allow_replica=False),
    )

    # then: everything allocated from the hinted warehouse only
    allocation = Allocation.objects.get(order_line=order_line, stock=stock_low)
    assert allocation.quantity_allocated == 3
    stock_low.refresh_from_db()
    assert stock_low.quantity_allocated == 3
    assert not Allocation.objects.filter(
        order_line=order_line, stock=stock_high
    ).exists()
    stock_high.refresh_from_db()
    assert stock_high.quantity_allocated == 0


def test_allocate_stocks_ft_warehouse_hint_insufficient_raises(
    order_line, variant_with_many_stocks, channel_USD
):
    # given: hinted warehouse only holds 3, order needs 5 (other warehouse has 4)
    variant = variant_with_many_stocks
    stock_low = variant.stocks.get(quantity=3)
    order_line.quantity = 5
    order_line.save(update_fields=["quantity"])
    _stamp_order_shipping_hint(order_line.order, stock_low.warehouse)

    line_data = OrderLineInfo(line=order_line, variant=variant, quantity=5)

    # when / then: strict — do not spill over to the other warehouse
    with pytest.raises(InsufficientStock):
        allocate_stocks(
            [line_data],
            COUNTRY_CODE,
            channel_USD,
            manager=get_plugins_manager(allow_replica=False),
        )

    assert not Allocation.objects.filter(order_line=order_line).exists()


def test_allocate_stocks_without_ft_warehouse_hint_uses_default(
    order_line, variant_with_many_stocks, channel_USD
):
    # given: no hint stamped -> default (PRIORITIZE_HIGH_STOCK) behavior
    variant = variant_with_many_stocks
    stock_high = variant.stocks.get(quantity=4)
    stock_low = variant.stocks.get(quantity=3)
    order_line.quantity = 3
    order_line.save(update_fields=["quantity"])
    assert FT_WAREHOUSE_METADATA_KEY not in (
        order_line.order.shipping_address.metadata or {}
    )

    line_data = OrderLineInfo(line=order_line, variant=variant, quantity=3)

    # when
    allocate_stocks(
        [line_data],
        COUNTRY_CODE,
        channel_USD,
        manager=get_plugins_manager(allow_replica=False),
    )

    # then: allocated from the highest-stock warehouse, unchanged from upstream
    allocation = Allocation.objects.get(order_line=order_line, stock=stock_high)
    assert allocation.quantity_allocated == 3
    assert not Allocation.objects.filter(
        order_line=order_line, stock=stock_low
    ).exists()


# --- reserve_stocks ---------------------------------------------------------


def test_reserve_stocks_constrained_to_ft_warehouse_hint(
    checkout_line, address, warehouse, shipping_zone, channel_USD
):
    # given: variant stocked in two warehouses; hinted one has the *lower* stock
    checkout_line.quantity = 5
    checkout_line.save(update_fields=["quantity"])

    primary_stock = Stock.objects.get(product_variant=checkout_line.variant)
    primary_stock.quantity = 10  # default strategy would prefer this one
    primary_stock.save(update_fields=["quantity"])

    secondary_warehouse = Warehouse.objects.create(
        address=address.get_copy(),
        name="Warehouse 2",
        slug="warehouse-2",
        email=warehouse.email,
    )
    secondary_warehouse.shipping_zones.add(shipping_zone)
    secondary_warehouse.channels.add(channel_USD)
    secondary_stock = Stock.objects.create(
        warehouse=secondary_warehouse,
        product_variant=primary_stock.product_variant,
        quantity=5,
    )

    # stamp the hint on the checkout shipping address, pointing at the secondary
    shipping_address = address.get_copy()
    shipping_address.metadata = {
        FT_WAREHOUSE_METADATA_KEY: _warehouse_gid(secondary_warehouse)
    }
    shipping_address.save(update_fields=["metadata"])
    checkout = checkout_line.checkout
    checkout.shipping_address = shipping_address
    checkout.save(update_fields=["shipping_address"])

    # when
    reserve_stocks(
        [checkout_line],
        [checkout_line.variant],
        COUNTRY_CODE,
        channel_USD,
        timezone.now() + datetime.timedelta(minutes=RESERVATION_LENGTH),
    )

    # then: reserved from the hinted warehouse only
    reservation = Reservation.objects.get(
        checkout_line=checkout_line, stock=secondary_stock
    )
    assert reservation.quantity_reserved == 5
    assert not Reservation.objects.filter(
        checkout_line=checkout_line, stock=primary_stock
    ).exists()
