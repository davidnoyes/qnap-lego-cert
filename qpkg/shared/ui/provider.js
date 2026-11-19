// DNS provider page: choosing a provider shows its steps straight away. This only
// changes what the page shows; nothing is saved until Apply. Without scripts, the
// form's Show button does the same.
(function () {
  var sel = document.getElementById('p');
  if (!sel || !sel.form) return;
  var btn = document.getElementById('p-show');
  if (btn) btn.hidden = true;
  sel.addEventListener('change', function () { sel.form.submit(); });
})();
