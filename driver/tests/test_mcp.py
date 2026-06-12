"""Tests for MCP server functionality."""

from typing import Any

from supex_driver.mcp.mcp_server import mcp


class TestMCPServer:
    """Test MCP server functionality."""

    def test_mcp_server_exists(self) -> None:
        """Test that MCP server instance exists."""
        assert mcp is not None
        assert mcp.name == "Supex"

    def test_server_has_tools(self) -> None:
        """Test that server has expected tools."""
        # Test that tools are registered by checking if decorators work
        expected_tools = [
            # Primary execution
            "eval_ruby",
            "eval_ruby_file",
            # Introspection
            "get_model_info",
            "list_entities",
            "get_selection",
            "get_layers",
            "get_materials",
            "get_camera_info",
            "get_context_snapshot",
            "snapshot_scope",
            "verify_scope",
            "get_entity_tree",
            "find_entities",
            "get_entity_details",
            "list_scenes",
            "set_camera",
            "validate_model",
            "take_screenshot",
            "take_batch_screenshots",
            # Model management
            "open_model",
            "save_model",
            "export_scene",
            # Status
            "check_status",
        ]

        # Since FastMCP doesn't expose internal tools directly,
        # we test that the functions exist in the module
        from supex_driver.mcp import mcp_server as server

        for expected_tool in expected_tools:
            assert hasattr(server, expected_tool), f"Missing tool: {expected_tool}"

    def test_context_snapshot_wrapper_forwards_bounds(self, monkeypatch: Any) -> None:
        """Test get_context_snapshot forwards bounded summary parameters."""
        from supex_driver.mcp import mcp_server as server

        calls: list[tuple[str, dict[str, Any], str]] = []

        def fake_call_tool(
            _ctx: Any,
            method: str,
            params: dict[str, Any] | None = None,
            operation: str = "operation",
        ) -> str:
            calls.append((method, params or {}, operation))
            return "{}"

        monkeypatch.setattr(server, "call_tool", fake_call_tool)

        assert server.get_context_snapshot(None, max_selection=7, max_validation_issues=3) == "{}"  # type: ignore[arg-type]
        assert calls == [
            (
                "get_context_snapshot",
                {"max_selection": 7, "max_validation_issues": 3},
                "get_context_snapshot",
            )
        ]

    def test_snapshot_scope_wrapper_forwards_default_grounding_policy(
        self, monkeypatch: Any
    ) -> None:
        """Test snapshot_scope defaults to selected visible unlocked scope."""
        from supex_driver.mcp import mcp_server as server

        calls: list[tuple[str, dict[str, Any], str]] = []

        def fake_call_tool(
            _ctx: Any,
            method: str,
            params: dict[str, Any] | None = None,
            operation: str = "operation",
        ) -> str:
            calls.append((method, params or {}, operation))
            return "{}"

        monkeypatch.setattr(server, "call_tool", fake_call_tool)

        assert server.snapshot_scope(None) == "{}"  # type: ignore[arg-type]
        method, params, operation = calls[0]
        assert method == "snapshot_scope"
        assert operation == "snapshot_scope"
        assert params["source"] == "selection"
        assert params["visibility"] == "visible_only"
        assert params["skip_locked"] is True
        assert params["include_faces_edges"] is False

    def test_batch_screenshot_wrapper_forwards_scope_views(
        self, monkeypatch: Any
    ) -> None:
        """Test scoped batch screenshot options are passed to the runtime."""
        from supex_driver.mcp import mcp_server as server

        calls: list[tuple[str, dict[str, Any], str]] = []

        def fake_call_tool(
            _ctx: Any,
            method: str,
            params: dict[str, Any] | None = None,
            operation: str = "operation",
        ) -> str:
            calls.append((method, params or {}, operation))
            return "{}"

        monkeypatch.setattr(server, "call_tool", fake_call_tool)

        assert (
            server.take_batch_screenshots(
                None,  # type: ignore[arg-type]
                shots=[],
                scope_entity_ids=[101, 202],
                standard_scope_views=True,
            )
            == "{}"
        )
        method, params, operation = calls[0]
        assert method == "take_batch_screenshots"
        assert operation == "take_batch_screenshots"
        assert params["scope_entity_ids"] == [101, 202]
        assert params["standard_scope_views"] is True

    def test_verify_scope_wrapper_forwards_scope_and_screenshot_policy(
        self, monkeypatch: Any
    ) -> None:
        """Test verify_scope forwards scope and proof-view options."""
        from supex_driver.mcp import mcp_server as server

        calls: list[tuple[str, dict[str, Any], str]] = []

        def fake_call_tool(
            _ctx: Any,
            method: str,
            params: dict[str, Any] | None = None,
            operation: str = "operation",
        ) -> str:
            calls.append((method, params or {}, operation))
            return "{}"

        monkeypatch.setattr(server, "call_tool", fake_call_tool)

        assert (
            server.verify_scope(
                None,  # type: ignore[arg-type]
                source="entity_ids",
                entity_ids=[303],
                standard_scope_views=["top", "iso"],
                include_screenshots=True,
            )
            == "{}"
        )
        method, params, operation = calls[0]
        assert method == "verify_scope"
        assert operation == "verify_scope"
        assert params["source"] == "entity_ids"
        assert params["entity_ids"] == [303]
        assert params["standard_scope_views"] == ["top", "iso"]
        assert params["include_screenshots"] is True


def test_version_exists() -> None:
    """Test that version is properly defined."""
    import re

    from supex_driver import __version__

    assert re.match(r"\d+\.\d+\.\d+", __version__)
