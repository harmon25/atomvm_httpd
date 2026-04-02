//
//     # ----------------------------------------------------------------------------
//     # "THE BEER-WARE LICENSE" (Revision 42):
//     # <fred@dushin.net> wrote this file.  You are hereby granted permission to
//     # copy, modify, or mutilate this file without restriction.  If you create a
//     # work derived from this file, you may optionally include a copy of this notice,
//     # for which I would be most grateful, but you are not required to do so.
//     # If we meet some day, and you think this stuff is worth it, you can buy me a
//     # beer in return.   Fred Dushin
//     # ----------------------------------------------------------------------------
//

// Vanilla JS implementation for AtomVM Web Console

// --- System Info Fetch and Render ---
function fetchSystemInfo() {
	fetch('/api/system_info')
		.then(function(response) { return response.json(); })
		.then(function(data) {
			// If esp32_chip_info exists, flatten it
			if (data.esp32_chip_info) {
				data.chip_model = data.esp32_chip_info.model;
				data.chip_cores = data.esp32_chip_info.cores;
				data.chip_features = data.esp32_chip_info.features;
				data.chip_revision = data.esp32_chip_info.revision;
			}
			renderSystemInfo(data);
		})
		.catch(function(err) {
			console.log(err)
			document.getElementById('system-view').innerHTML = '<div style="color:red">Failed to load system info</div>';
		});
}

function renderSystemInfo(data) {
	var html = `<table>
		<tr><td>platform</td><td>${data.platform ?? ''}</td></tr>
		<tr><td>system_architecture</td><td>${data.system_architecture ?? ''}</td></tr>
		<tr><td>word_size</td><td>${data.word_size ?? ''}</td></tr>
		<tr><td>chip_model</td><td>${data.chip_model ?? ''}</td></tr>
		<tr><td>chip_cores</td><td>${data.chip_cores ?? ''}</td></tr>
		<tr><td>chip_features</td><td>${data.chip_features ?? ''}</td></tr>
		<tr><td>chip_revision</td><td>${data.chip_revision ?? ''}</td></tr>
		<tr><td>atomvm_version</td><td>${data.atomvm_version ?? ''}</td></tr>
		<tr><td>esp_idf_version</td><td>${data.esp_idf_version ?? ''}</td></tr>
	</table>`;
	document.getElementById('system-view').innerHTML = html;
}

// --- Memory Info Fetch and Render ---
let memoryData = {};
function fetchMemoryInfo() {
	fetch('/api/memory')
		.then(function(response) { return response.json(); })
		.then(function(data) {
			memoryData = data;
			renderMemoryInfo(data);
		})
		.catch(function(err) {
			document.getElementById('memory-view').innerHTML = '<div style="color:red">Failed to load memory info</div>';
		});
}

function renderMemoryInfo(data) {
	var html = `<table>
		<tr><td>atom_count</td><td>${data.atom_count ?? ''}</td></tr>
		<tr><td>port_count</td><td>${data.port_count ?? ''}</td></tr>
		<tr><td>process_count</td><td>${data.process_count ?? ''}</td></tr>
		<tr><td>esp32_free_heap_size</td><td>${data.esp32_free_heap_size ?? ''}</td></tr>
		<tr><td>esp32_largest_free_block</td><td>${data.esp32_largest_free_block ?? ''}</td></tr>
		<tr><td>esp32_minimum_free_size</td><td>${data.esp32_minimum_free_size ?? ''}</td></tr>
	</table>`;
	document.getElementById('memory-view').innerHTML = html;
}

// --- WebSocket for live memory updates ---
function getWebSocketUrl() {
	var hostname = window.location.hostname;
	var port = window.location.port;
	return "ws://" + hostname + (port ? ":" + port : "") + "/ws";
}

function createWebSocket() {
	var ws = new window.WebSocket(getWebSocketUrl());
	ws.onmessage = function(event) {
		try {
			var data = JSON.parse(event.data);
			// Only update known memory fields
			let changed = false;
			for (var key in data) {
				if (Object.prototype.hasOwnProperty.call(memoryData, key) && data[key] !== memoryData[key]) {
					memoryData[key] = data[key];
					changed = true;
				}
			}
			if (changed) {
				renderMemoryInfo(memoryData);
			}
		} catch (e) {
			// ignore parse errors
		}
	};
	ws.onopen = function(event) {
		console.log("WebSocket opened");
	};
	ws.onclose = function(event) {
		console.log("WebSocket closed, reconnecting...");
		setTimeout(createWebSocket, 2000);
	};
	ws.onerror = function(event) {
		console.log("WebSocket error");
	};
	return ws;
}

// --- Initialization ---
document.addEventListener('DOMContentLoaded', function() {
	// Hide loader and show content after 1s
	setTimeout(function() {
		var loader = document.getElementById('loader');
		var content = document.getElementById('content');
		if (loader) loader.style.display = 'none';
		if (content) content.style.display = 'block';
	}, 1000);

	// Tab switching logic
	var tabBtns = document.querySelectorAll('.tab-btn');
	tabBtns.forEach(function(btn) {
		btn.addEventListener('click', function() {
			tabBtns.forEach(function(b) { b.classList.remove('active'); });
			document.querySelectorAll('.panel').forEach(function(p) { p.classList.remove('active'); });
			btn.classList.add('active');
			var panel = document.getElementById(btn.getAttribute('data-panel'));
			if (panel) panel.classList.add('active');
		});
	});

	fetchSystemInfo();
	fetchMemoryInfo();
	createWebSocket();
});
