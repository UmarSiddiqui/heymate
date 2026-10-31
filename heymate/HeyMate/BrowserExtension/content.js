/*
 * HeyMate Chrome Extension Content Script
 * Injected into web pages to capture accessibility tree and element info.
 * Communicates with the background script via chrome.runtime.sendMessage.
 */

(function() {
  'use strict';

  // Map Chrome ARIA roles to accessibility roles
  function mapRole(element) {
    const role = element.getAttribute('role');
    const tagName = element.tagName.toLowerCase();
    const type = element.getAttribute('type');

    if (role) return role;
    if (tagName === 'button') return 'AXButton';
    if (tagName === 'input') {
      if (type === 'text' || type === 'search' || type === 'email' || type === 'password' || type === 'tel' || type === 'url') return 'AXTextField';
      if (type === 'checkbox') return 'AXCheckBox';
      if (type === 'radio') return 'AXRadioButton';
      if (type === 'submit' || type === 'button') return 'AXButton';
      return 'AXTextField';
    }
    if (tagName === 'textarea') return 'AXTextArea';
    if (tagName === 'select') return 'AXPopUpButton';
    if (tagName === 'a') return 'AXLink';
    if (tagName === 'img') return 'AXImage';
    if (tagName === 'link') return 'AXLink';
    return 'AXGenericElement';
  }

  function getElementInfo(element) {
    const rect = element.getBoundingClientRect();
    const role = mapRole(element);
    const label = element.getAttribute('aria-label') ||
                  element.getAttribute('aria-labelledby') ||
                  element.textContent?.trim().substring(0, 100) ||
                  element.getAttribute('title') ||
                  element.placeholder ||
                  element.value ||
                  '';
    const value = element.getAttribute('value') || element.value || '';
    const disabled = element.hasAttribute('disabled') || element.disabled;
    const readonly = element.hasAttribute('readonly');
    const hidden = element.hidden || element.style.display === 'none' || element.style.visibility === 'hidden';
    const clickable = element.tagName === 'BUTTON' ||
                      element.tagName === 'A' ||
                      element.tagName === 'INPUT' ||
                      element.getAttribute('role') === 'button' ||
                      element.getAttribute('role') === 'link' ||
                      element.onclick !== null;

    return {
      ref: element.dataset.heymateRef || element.getAttribute('data-heymate-ref') || '',
      role: role,
      label: label.trim().substring(0, 200),
      value: value || '',
      rect: {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      },
      isFocused: element === document.activeElement,
      isEditable: element.isContentEditable ||
                 element.tagName === 'INPUT' ||
                 element.tagName === 'TEXTAREA' ||
                 element.isContentEditable,
      isDisabled: disabled || readonly,
      isHidden: hidden,
      isClickable: clickable
    };
  }

  function captureSnapshot() {
    const elements = [];
    const visibleStrings = [];

    // Collect all interactive elements
    const interactiveSelectors = [
      'button', 'a', 'input', 'select', 'textarea',
      '[role="button"]', '[role="link"]', '[role="textbox"]',
      '[role="checkbox"]', '[role="radio"]', '[role="menuitem"]',
      '[role="tab"]', '[role="combobox"]', '[role="slider"]',
      '[contenteditable="true"]', '[contenteditable="true"]'
    ];

    const allElements = document.querySelectorAll(interactiveSelectors.join(','));

    allElements.forEach((el, index) => {
      const info = getElementInfo(el);
      if (info.label || info.role) {
        // Assign a ref if not already set
        if (!info.ref) {
          info.ref = 'e' + (index + 1);
          el.setAttribute('data-heymate-ref', info.ref);
        }
        elements.push(info);
      }
    });

    // Collect visible text
    const walker = document.createTreeWalker(
      document.body,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode: function(node) {
          const text = node.textContent.trim();
          if (text.length > 0 && text.length < 200) {
            return NodeFilter.FILTER_ACCEPT;
          }
          return NodeFilter.FILTER_REJECT;
        }
      });

      let node;
      while (node = walker.nextNode()) {
        visibleStrings.push(node.textContent.trim());
      }

    return { elements, visibleStrings };
  }

  // Expose captureSnapshot for background script to call via chrome.tabs.sendMessage
  window.heyMateCapture = captureSnapshot;

  // Listen for messages from background script
  chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.type === 'captureSnapshot') {
      const result = captureSnapshot();
      sendResponse({ result });
      return true;
    }
    return false;
  });

  // Notify background script that content script is ready
  chrome.runtime.sendMessage({ type: 'contentReady' });
})();
