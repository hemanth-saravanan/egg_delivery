const String googleScriptCode = r'''
function doGet(e) {
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName("Sheet1");
  var lastRow = sheet.getLastRow();
  

  if (lastRow < 2) {
    return ContentService.createTextOutput(JSON.stringify([]))
      .setMimeType(ContentService.MimeType.JSON);
  }

  var range = sheet.getRange(2, 1, lastRow - 1, 6);
  var values = range.getValues();
  var backgrounds = range.getBackgrounds();

  var data = [];

  for (var i = 0; i < values.length; i++) {
    // Stop reading if the first column (Name) is empty
    if (values[i][0] === "") break;

    var color = backgrounds[i][0].toLowerCase(); // Check color of Column A
    var status = "pending";

    if (color == "#b6d7a8") status = "complete";
    if (color == "#ea9999") status = "texted";

    data.push({
      "name": values[i][0],
      "address": values[i][1],
      "phone": values[i][2],
      "dozens": values[i][3],
      "notes": values[i][4],
      "coords": values[i][5],
      "status": status,
      "originalRow": i + 2 // Row index for updates
    });
  }

  return ContentService.createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}

function doPost(e) {
  var params = JSON.parse(e.postData.contents);
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName("Sheet1");

  if (params.action == "reorder") {
    var indices = params.indices; // Array of original row numbers
    var lastRow = sheet.getLastRow();
    if (lastRow < 2) return ContentService.createTextOutput(JSON.stringify({"status": "success"}));

    var range = sheet.getRange(2, 1, lastRow - 1, 6);
    var values = range.getValues();
    var backgrounds = range.getBackgrounds();
    
    var rowMap = {};
    for (var i = 0; i < values.length; i++) {
      rowMap[i + 2] = { "val": values[i], "bg": backgrounds[i] };
    }
    
    var newValues = [];
    var newBg = [];
    
    for (var k = 0; k < indices.length; k++) {
      var idx = indices[k];
      if (rowMap[idx]) {
        newValues.push(rowMap[idx].val);
        newBg.push(rowMap[idx].bg);
        delete rowMap[idx];
      }
    }

    for (var key in rowMap) {
      newValues.push(rowMap[key].val);
      newBg.push(rowMap[key].bg);
    }
    
    range.setValues(newValues);
    range.setBackgrounds(newBg);
    
    return ContentService.createTextOutput(JSON.stringify({"status": "success"}));
  }

  var rowIndex = params.row;
  var action = params.status;
  var range = sheet.getRange(rowIndex, 1, 1, 6);
  
  if (action == "texted") range.setBackground("#ea9999");
  else range.setBackground("#b6d7a8");

  return ContentService.createTextOutput(JSON.stringify({"status": "success"}));
}
''';
