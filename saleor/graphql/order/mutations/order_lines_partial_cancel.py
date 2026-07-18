import graphene

from ....order import events
from ....order.error_codes import OrderErrorCode
from ....order.fetch import OrderLineInfo
from ....order.lock_objects import order_qs_select_for_update
from ....order.search import update_order_search_vector
from ....order.utils import (
    change_order_line_quantity,
    invalidate_order_prices,
    recalculate_order_weight,
)
from ....permission.enums import OrderPermissions
from ....warehouse.management import decrease_allocations
from ...app.dataloaders import get_app_promise
from ...core import ResolveInfo
from ...core.context import SyncWebhookControlContext
from ...core.doc_category import DOC_CATEGORY_ORDERS
from ....core.tracing import traced_atomic_transaction
from ...core.mutations import BaseMutation
from ...core.types import NonNullList, OrderError
from ...plugins.dataloaders import get_plugin_manager_promise
from ..types import Order, OrderLine
from .utils import call_event_by_order_status

# FreshTerra partial-cancel contract (FRES-1005 / FRES-958).
#
# ERPNext can cancel a single Delivery Note (a subset of an order's lines) BEFORE
# it is packed. Stock Saleor forbids editing the lines of a *confirmed* order
# (`orderLineUpdate`/`orderLineDelete` raise NOT_EDITABLE), so a subset cannot be
# deallocated through the standard mutations, and `orderCancel` is all-or-nothing.
#
# This FreshTerra mutation releases the Saleor allocation for the *specified line
# quantities* on any order — including a confirmed/unfulfilled one — and reduces
# (or removes) those lines, leaving the rest of the order live. It deliberately
# omits the editable-order guard; it is scoped to unfulfilled quantities only
# (a packed/fulfilled quantity can never be reached — DN cancel is rejected once
# the DN is PACKED), and it composes Saleor's own primitives
# (`decrease_allocations`, `change_order_line_quantity`) so allocation + price +
# weight accounting stays consistent. The backend refunds those lines separately.


class OrderLinePartialCancelInput(graphene.InputObjectType):
    order_line_id = graphene.ID(
        required=True, description="ID of the order line to partially cancel."
    )
    quantity = graphene.Int(
        required=True, description="Unfulfilled quantity to cancel (deallocate)."
    )


class OrderLinesPartialCancel(BaseMutation):
    order = graphene.Field(Order, description="The order the lines belong to.")

    class Arguments:
        id = graphene.ID(required=True, description="ID of the order.")
        lines = NonNullList(
            OrderLinePartialCancelInput,
            required=True,
            description="Line quantities to cancel (deallocate + remove/reduce).",
        )

    class Meta:
        description = (
            "FreshTerra: deallocate and remove a subset of an order's unfulfilled "
            "line quantities without cancelling the whole order (pre-PACKED DN cancel)."
        )
        doc_category = DOC_CATEGORY_ORDERS
        permissions = (OrderPermissions.MANAGE_ORDERS,)
        error_type_class = OrderError
        error_type_field = "order_errors"

    @classmethod
    def _resolve_targets(cls, info: ResolveInfo, order, lines):
        """Map each input to its (line, quantity), validating ownership + quantity."""
        targets = []
        for entry in lines:
            line = cls.get_node_or_error(
                info, entry["order_line_id"], only_type=OrderLine
            )
            if line.order_id != order.pk:
                cls._raise(
                    "order_line_id",
                    "Order line does not belong to this order.",
                )
            quantity = entry["quantity"]
            unfulfilled = line.quantity - line.quantity_fulfilled
            if quantity < 1 or quantity > unfulfilled:
                cls._raise(
                    "quantity",
                    f"Quantity must be between 1 and the unfulfilled quantity "
                    f"({unfulfilled}) of the line.",
                )
            if line.is_gift:
                cls._raise("order_line_id", "A gift line cannot be cancelled.")
            targets.append((line, quantity))
        return targets

    @classmethod
    def _raise(cls, field, message):
        from ...core.utils import raise_validation_error

        raise_validation_error(
            field=field, message=message, code=OrderErrorCode.INVALID.value
        )

    @classmethod
    def perform_mutation(  # type: ignore[override]
        cls, _root, info: ResolveInfo, /, *, id, lines
    ):
        manager = get_plugin_manager_promise(info.context).get()
        app = get_app_promise(info.context).get()
        order = cls.get_node_or_error(info, id, only_type=Order)
        cls.check_channel_permissions(info, [order.channel_id])

        targets = cls._resolve_targets(info, order, lines)

        with traced_atomic_transaction():
            # Lock the order before touching lines (order → lines lock ordering).
            order_qs_select_for_update().only("pk").get(pk=order.pk)
            for line, quantity in targets:
                old_quantity = line.quantity
                new_quantity = old_quantity - quantity
                # Release exactly the cancelled quantity's allocation. Done
                # explicitly (not via change_order_line_quantity's allocate_stock
                # path) because delete_order_line skips deallocation on a confirmed
                # order — here we always release, confirmed or not.
                dealloc_info = OrderLineInfo(
                    line=line, quantity=quantity, variant=line.variant
                )
                decrease_allocations([dealloc_info], manager)
                if new_quantity > 0:
                    # Reduce the line + recalc its prices; allocations already handled.
                    change_order_line_quantity(
                        info.context.user,
                        app,
                        OrderLineInfo(
                            line=line, quantity=new_quantity, variant=line.variant
                        ),
                        old_quantity,
                        new_quantity,
                        order,
                        manager,
                        send_event=True,
                        allocate_stock=False,
                    )
                else:
                    events.order_removed_products_event(
                        order=order,
                        user=info.context.user,
                        app=app,
                        order_lines=[line],
                        quantity_diff=quantity,
                    )
                    line.delete()

            invalidate_order_prices(order)
            recalculate_order_weight(order)
            update_order_search_vector(order, save=False)
            order.lines_count = order.lines.count()
            order.save(
                update_fields=[
                    "should_refresh_prices",
                    "weight",
                    "search_vector",
                    "updated_at",
                    "lines_count",
                ]
            )
            call_event_by_order_status(order, manager)

        return OrderLinesPartialCancel(order=SyncWebhookControlContext(order))
