var guessGem = function(frame) {
  var split = frame.split('/gems/');
  if(split.length == 1) {
    split = frame.split('/app/');
    if(split.length == 1) {
      split = frame.split('/lib/');
    } else {
      return split[split.length-1].split('/')[0]
    }

    split = split[Math.max(split.length-2,0)].split('/');
    return split[split.length-1].split(':')[0];
  }
  else
  {
    return split[split.length -1].split('/')[0].split('-', 2)[0];
  }
}

var color = function() {
  var r = parseInt(205 + Math.random() * 50);
  var g = parseInt(Math.random() * 230);
  var b = parseInt(Math.random() * 55);
  return "rgb(" + r + "," + g + "," + b + ")";
}

// http://stackoverflow.com/a/7419630
var rainbow = function(numOfSteps, step) {
    // This function generates vibrant, "evenly spaced" colours (i.e. no clustering). This is ideal for creating easily distiguishable vibrant markers in Google Maps and other apps.
    // Adam Cole, 2011-Sept-14
    // HSV to RBG adapted from: http://mjijackson.com/2008/02/rgb-to-hsl-and-rgb-to-hsv-color-model-conversion-algorithms-in-javascript
    var r, g, b;
    var h = step / numOfSteps;
    var i = ~~(h * 6);
    var f = h * 6 - i;
    var q = 1 - f;
    switch(i % 6){
        case 0: r = 1, g = f, b = 0; break;
        case 1: r = q, g = 1, b = 0; break;
        case 2: r = 0, g = 1, b = f; break;
        case 3: r = 0, g = q, b = 1; break;
        case 4: r = f, g = 0, b = 1; break;
        case 5: r = 1, g = 0, b = q; break;
    }
    var c = "#" + ("00" + (~ ~(r * 255)).toString(16)).slice(-2) + ("00" + (~ ~(g * 255)).toString(16)).slice(-2) + ("00" + (~ ~(b * 255)).toString(16)).slice(-2);
    return (c);
}

// http://stackoverflow.com/questions/1960473/unique-values-in-an-array
var getUnique = function(orig) {
    var o = {}, a = []
    for (var i = 0; i < orig.length; i++) o[orig[i]] = 1
    for (var e in o) a.push(e)
    return a
}

function flamegraph(data) {
  var maxX = 0;
  var maxY = 0;
  var minY = 10000;
  $.each(data, function(){
     maxX = Math.max(maxX, this.x + this.width);
     maxY = Math.max(maxY, this.y);
     minY = Math.min(minY, this.y);
  });

  // normalize Y
  if (minY > 0) {
    $.each(data, function(){
      this.y -= minY
    })
    maxY -= minY
    minY = 0
  }

  var margin = {top: 10, right: 10, bottom: 10, left: 10}
  var width = $(window).width() - 200 - margin.left - margin.right;
  var height = $(window).height() * 0.70 - margin.top - margin.bottom;
  var height2 = $(window).height() * 0.30 - 60 - margin.top - margin.bottom;

  $('.flamegraph').width(width + margin.left + margin.right).height(height + margin.top + margin.bottom);
  $('.zoom').width(width + margin.left + margin.right).height(height2 + margin.top + margin.bottom);

  var xScale = d3.scale.linear()
    .domain([0, maxX])
    .range([0, width]);

  var xScale2 = d3.scale.linear()
    .domain([0, maxX])
    .range([0, width])

  var yScale = d3.scale.linear()
      .domain([0, maxY])
      .range([0,height]);

  var yScale2 = d3.scale.linear()
      .domain([0, maxY])
      .range([0,height2]);

  var zoomXRatio = 1
  var zoomed = function() {
    svg.attr("transform", "translate(" + d3.event.translate + ")" + " scale(" + (zoomXRatio*d3.event.scale) + "," + d3.event.scale + ")");

    var x = xScale.domain(), y = yScale.domain()
    brush.extent([ [x[0]/zoomXRatio, y[0]], [x[1]/zoomXRatio, y[1]] ])
    if (x[1] == maxX && y[1] == maxY)
      brush.clear()
    svg2.select('g.brush').call(brush)
  }

  var zoom = d3.behavior.zoom().x(xScale).y(yScale).scaleExtent([1, 14]).on('zoom', zoomed)

  var svg2 = d3.select('.zoom').append('svg').attr('width', '100%').attr('height', '100%').append('svg:g')
                      .attr("transform", "translate(" + margin.left + "," + margin.top + ")")
                      .append('g').attr('class', 'graph')

  var svg = d3.select(".flamegraph")
                      .append("svg")
                      .attr("width", "100%")
                      .attr("height", "100%")
                      .attr("pointer-events", "all")
                      .append('svg:g')
                      .attr("transform", "translate(" + margin.left + "," + margin.top + ")")
                      .call(zoom)
                      .append('svg:g').attr('class', 'graph');

  // so zoom works everywhere
  svg.append("rect")
      .attr("x",function(d) { return xScale(0); })
      .attr("y",function(d) { return yScale(0);})
      .attr("width", function(d){return xScale(maxX);})
      .attr("height", yScale(maxY))
      .attr("fill", "white");

  var samplePercentRaw = function(samples, exclusive) {
    var ret = [samples, ((samples / maxX) * 100).toFixed(2)]
    if (exclusive)
      ret = ret.concat([exclusive, ((exclusive / maxX) * 100).toFixed(2)])
    return ret;
  }

  var samplePercent = function(samples, exclusive) {
    var info = samplePercentRaw(samples, exclusive)
    var samplesPct = info[1], exclusivePct = info[3]
    var ret = " (" + samples + " sample" + (samples == 1 ? "" : "s") + " - " + samplesPct + "%) ";
    if (exclusive)
      ret += " (" + exclusive + " exclusive - " + exclusivePct + "%) ";
    return ret;
  }

  var info = {};

  var mouseover =  function(d) {
    var i = info[d.frame_id];
    var shortFile = d.file.replace(/^.+\/(gems|app|lib|config|jobs)/, '$1')
    var data = samplePercentRaw(i.samples.length, d.topFrame ? d.topFrame.exclusiveCount : 0)

    $('.info')
      .css('background-color', i.color)
      .find('.frame').text(d.frame).end()
      .find('.file').text(shortFile).end()
      .find('.samples').text(data[0] + ' samples ('+data[1]+'%)').end()
      .find('.exclusive').text('')

    if (data[3])
      $('.info .exclusive').text(data[2] + ' exclusive ('+data[3]+'%)')

    d3.selectAll(i.nodes)
       .attr('opacity',0.5);
  };

  var mouseout = function(d) {
    var i = info[d.frame_id];
    $('.info').css('background-color', 'none').find('.frame, .file, .samples, .exclusive').text('')

    d3.selectAll(i.nodes)
       .attr('opacity',1);
  };

  // assign some colors, analyze samples per gem
  var gemStats = {}
  var topFrames = {}
  var lastFrame = {frame: 'd52e04d-df28-41ed-a215-b6ec840a8ea5', x: -1}

  $.each(data, function(){
    var gem = guessGem(this.file);
    var stat = gemStats[gem];
    this.gemName = gem

    if(!stat) {
      gemStats[gem] = stat = {name: gem, samples: [], frames: [], nodes:[]};
    }

    stat.frames.push(this.frame_id);
    for(var j=0; j < this.width; j++){
      stat.samples.push(this.x + j);
    }
    // This assumes the traversal is in order
    if (lastFrame.x != this.x) {
      var topFrame = topFrames[lastFrame.frame_id]
      if (!topFrame) {
        topFrames[lastFrame.frame_id] = topFrame = {exclusiveCount: 0}
      }
      topFrame.exclusiveCount += 1;
      lastFrame.topFrame = topFrame;
    }
    lastFrame = this;

  });

  var topFrame = topFrames[lastFrame.frame_id]
  if (!topFrame) {
    topFrames[lastFrame.frame_id] = topFrame = {exclusiveCount: 0}
  }
  topFrame.exclusiveCount += 1;
  lastFrame.topFrame = topFrame;

  var totalGems = 0;
  $.each(gemStats, function(k,stat){
    totalGems++;
    stat.samples = getUnique(stat.samples);
  });

  var gemsSorted = $.map(gemStats, function(v, k){ return v })
  gemsSorted.sort(function(a, b){ return b.samples.length - a.samples.length })

  var currentIndex = 0;
  $.each(gemsSorted, function(k,stat){
    stat.color = rainbow(totalGems, currentIndex);
    currentIndex += 1;

    for(var x=0; x < stat.frames.length; x++) {
      info[stat.frames[x]] = {nodes: [], samples: [], color: stat.color};
    }
  });

  function drawData(svg, data, xScale, yScale, mini) {
  svg.selectAll("g.flames")
    .data(data)
    .enter()
      .append("g")
      .attr('class', 'flames')
      .each(function(d){
        gemStats[d.gemName].nodes.push(this)

        var r = d3.select(this)
        .append("rect")
        .attr("x",function(d) { return xScale(d.x); })
        .attr("y",function(d) { return yScale(maxY - d.y);})
        .attr("width", function(d){return xScale(d.width);})
        .attr("height", yScale(1))
        .attr("fill", function(d){
          var i = info[d.frame_id];
          if(!i) {
            info[d.frame_id] = i = {nodes: [], samples: [], color: color()};
          }
          i.nodes.push(this);
          if (!mini)
            for(var j=0; j < d.width; j++){
              i.samples.push(d.x + j);
            }
          return i.color;
        })

        if (!mini)
          r
          .on("mouseover", mouseover)
          .on("mouseout", mouseout);

        if (!mini)
          d3.select(this)
            .append('foreignObject')
            .classed('label-body', true)
            .attr("x",function(d) { return xScale(d.x); })
            .attr("y",function(d) { return yScale(maxY - d.y);})
            .attr("width", function(d){return xScale(d.width);})
            .attr("height", yScale(1))
            .attr("line-height", yScale(1))
            .attr("font-size", yScale(0.42) + 'px')
            .attr('pointer-events', 'none')
            .append('xhtml:span')
            .style("height", yScale(1))
            .classed('label', true)
            .text(function(d){ return d.frame })
      });
  }

  drawData(svg, data, xScale, yScale, 0)
  drawData(svg2, data, xScale2, yScale2, 1)

  var brushed = function(){
    if (brush.empty()) {
      svg.attr('transform', '')
      zoomXRatio = 1
      zoom.scale(1).translate([0,0])
      svg.selectAll('.label-body')
         .attr('transform', 'scale(1,1)')
         .attr("x",function(d) { return xScale(d.x)*zoomXRatio; })
         .attr("width", function(d){return xScale(d.width)*zoomXRatio;})
    } else {
      var e = brush.extent()
      var x = [e[0][0],e[1][0]], y = [e[0][1],e[1][1]]

      xScale.domain([0, maxX])
      yScale.domain([0, maxY])

      var w = width, h = height2
      var dx = xScale2(1.0*x[1]-x[0]), dy = yScale2(1.0*y[1]-y[0])
      var sx = w/dx, sy = h/dy
      var trlx = -xScale(x[0])*sx, trly = -yScale(y[0])*sy
      var transform = "translate(" + trlx + ',' + trly + ")" + " scale(" + sx + ',' + sy + ")"

      zoomXRatio = sx/sy

      svg.selectAll('.label-body')
         .attr("x",function(d) { return xScale(d.x)*zoomXRatio; })
         .attr("width", function(d){return xScale(d.width)*zoomXRatio;})
         .attr('transform', function(d){
           var x = xScale(d.x)
           return "scale("+(1.0/zoomXRatio)+",1)"
         })

      svg.attr("transform", transform)
      zoom.translate([trlx, trly]).scale(sy)
    }
  }

  var brush = d3.svg.brush()
      .x(xScale2)
      .y(yScale2)
      .on("brush", brushed);

  svg2.append("g")
        .attr("class", "brush")
        .call(brush)

  // Samples may overlap on the same line
  for (var r in info) {
    if (info[r].samples) {
      info[r].samples = getUnique(info[r].samples);
    }
  };

  // render the legend
  $.each(gemsSorted, function(k,gem){
    var data = samplePercentRaw(gem.samples.length)
    var node = $("<div class='"+gem.name+"'></div>")
      .css("background-color", gem.color)
      .html("<span style='float: right'>" + data[0] + 'x<br>' + data[1] + '%' + '</span>' + '<div class="name">'+gem.name+'<br>&nbsp;</div>');

    node.on('mouseenter mouseleave', function(e){
      d3.selectAll(gemStats[gem.name].nodes).classed('highlighted', e.type == 'mouseenter')
    })

    $('.legend').append(node);
  });
}
