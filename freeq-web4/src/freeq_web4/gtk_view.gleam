//// Deprecated re-export of the canonical view tree.
////
//// Prefer `freeq_web4/ui` types + `live.view_tree` / `live.ui_to_msg`.

import freeq_web4/live
import freeq_web4/ui
import gleam/option.{type Option}

pub type View =
  ui.View

pub type Node =
  ui.Node

pub type ButtonStyle =
  ui.ButtonStyle

pub type Event =
  ui.Event

pub fn from_model(model: live.Model) -> View {
  live.view_tree(model)
}

pub fn to_msg(event: Event, model: live.Model) -> Option(live.Msg) {
  live.ui_to_msg(event, model)
}
