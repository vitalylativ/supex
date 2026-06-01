# MCP Reference

Canonical MCP tool inventory for Supex.

Source of truth in code:

- `driver/src/supex_driver/mcp/mcp_server.py`
- `driver/src/supex_driver/mcp/vcad_tools.py`
- `driver/src/supex_driver/mcp/vcad_diagnostics.py`

Note: `reload_extension` is a CLI command (`./supex reload`), not an MCP tool.

## Core Status

| Tool | Description |
|------|-------------|
| `check_status` | Unified health check: SketchUp bridge, console capture, VCAD sidecar, VCAD viewer |

## Ruby Execution

| Tool | Description |
|------|-------------|
| `eval_ruby` | Execute inline Ruby code |
| `eval_ruby_file` | Execute Ruby from file path |

## Model Introspection

| Tool | Description |
|------|-------------|
| `get_model_info` | Model title, units, entity counts, modified state |
| `list_entities` | List entities with optional type filter |
| `get_selection` | List selected entities |
| `get_layers` | List layers/tags |
| `get_materials` | List materials |
| `get_camera_info` | Current camera info |

## Large-Model Navigation

| Tool | Description |
|------|-------------|
| `get_entity_tree` | Bounded hierarchy of groups/components, optionally rooted at an entity |
| `find_entities` | Search by text, type, name, tag/layer, material, or attribute |
| `get_entity_details` | Detailed summary for one entity by entity id or persistent id |
| `list_scenes` | List SketchUp scenes/pages with camera summaries |
| `set_camera` | Set the active SketchUp camera from eye/target/up coordinates |
| `validate_model` | Lightweight hygiene checks such as loose root geometry and empty containers |

### get_entity_tree

Inputs:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `root_id` | int/null | null | Optional entity id or persistent id to start from |
| `id_type` | string | `entity_id` | `entity_id` or `persistent_id` |
| `max_depth` | int | 3 | Maximum child depth |
| `include_faces_edges` | bool | false | Include raw face/edge nodes instead of container-only tree |

### find_entities

Inputs:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `query` | string | `""` | Free-text search over ids, type, name, definition, tag, material |
| `entity_type` | string | `all` | `all`, `containers`, `faces`, `edges`, `groups`, `components`, or typename |
| `name` | string/null | null | Name substring |
| `tag` | string/null | null | Tag/layer substring |
| `material` | string/null | null | Material substring |
| `attribute_dict` | string/null | null | Attribute dictionary name |
| `attribute_key` | string/null | null | Attribute key |
| `attribute_value` | string/null | null | Exact attribute value |
| `max_results` | int | 50 | Maximum results |
| `max_depth` | int | 8 | Recursive search depth |

### get_entity_details

Inputs:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `id` | int | required | Entity id or persistent id |
| `id_type` | string | `entity_id` | `entity_id` or `persistent_id` |
| `max_depth` | int | 1 | Child depth to include |
| `include_faces_edges` | bool | false | Include raw face/edge children |

### set_camera

Inputs:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `eye` | list[float] | required | Camera eye point `[x, y, z]` in SketchUp internal units |
| `target` | list[float] | required | Camera target point `[x, y, z]` |
| `up` | list[float]/null | `[0,0,1]` | Camera up vector |
| `fov` | float | 35.0 | Field of view |
| `perspective` | bool | true | Perspective projection |
| `zoom_extents` | bool | false | Zoom extents after setting camera |

### validate_model

Inputs:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `id` | int/null | null | Optional scope entity id or persistent id |
| `id_type` | string | `entity_id` | `entity_id` or `persistent_id` |

## Visualization

| Tool | Description |
|------|-------------|
| `take_screenshot` | Capture SketchUp view to PNG (returns file path) |
| `take_batch_screenshots` | Capture multiple camera shots in one batch |

## Model Management

| Tool | Description |
|------|-------------|
| `open_model` | Open `.skp` model by absolute path |
| `save_model` | Save current model (optionally to path) |
| `export_scene` | Export scene (`skp`, `obj`, `stl`, `png`, `jpg`, `jpeg`) |

## VCAD Authoring

For full workflow and semantics, see [VCAD Integration](vcad.md).

| Tool | Description |
|------|-------------|
| `vcad_place` | Evaluate `.cmp.oo` and place/update node in SketchUp (imports auto-resolved) |
| `vcad_update` | Re-evaluate node; with `cascade=true` also updates downstream dependents in DAG order |
| `vcad_inspect` | Evaluate and return geometry metadata |
| `vcad_eval` | REPL-like Loon evaluation |
| `vcad_list_nodes` | List VCAD nodes present in the model |
| `vcad_watch_pause` | Pause reactive watch processing |
| `vcad_watch_resume` | Resume and flush accumulated watch events |
| `vcad_export` | Sidecar export API surface (treat as experimental until fully wired end-to-end) |

## VCAD Viewer Relay

| Tool | Description |
|------|-------------|
| `vcad_viewer_state` | Get viewer state snapshot |
| `vcad_viewer_screenshot` | Save viewer screenshot to `.tmp/vcad-viewer/` |
| `vcad_viewer_focus` | Focus viewer camera on a node |

## VCAD Diagnostics

| Tool | Description |
|------|-------------|
| `vcad_metrics` | Operational telemetry snapshot |
| `vcad_reconcile_status` | Last reconciliation run state |
