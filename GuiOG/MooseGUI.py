# used to parse files more easily
from __future__ import with_statement
# Numpy module
import numpy as np
# for command-line arguments
import sys
#moose imports
import moose
from collections import defaultdict
from objectedit import ObjectFieldsModel, ObjectEditDelegate, ObjectEditView
# Qt4 bindings for core Qt functionalities (non-GUI)
from PyQt4 import QtCore
from PyQt4.QtCore import QEvent, Qt
# Python Qt4 bindings for GUI objects
from PyQt4 import QtGui
# import the MainWindow widget from the converted .ui files
from MooseLayout import Ui_MainWindow
#opengl imports
from PyQt4.QtOpenGL import QGLWidget
from OpenGL.GL import *
from updatepaintGL import updatepaintGL

mc=moose.context

class DesignerMainWindow(QtGui.QMainWindow, Ui_MainWindow):
    """Customization for Qt Designer created window"""
    def __init__(self, parent = None):
        # initialization of the superclass
        super(DesignerMainWindow, self).__init__(parent)
        # setup the GUI --> function generated by pyuic4
        self.setupUi(self)

	self.objFieldEditorMap = {}


	QtCore.QObject.connect(self.toolButton, QtCore.SIGNAL("clicked()"), self.update_graph) 
	QtCore.QObject.connect(self.toolButton_3, QtCore.SIGNAL("clicked()"), self.select_compartment)
	QtCore.QObject.connect(self.mtree,QtCore.SIGNAL('itemDoubleClicked(QTreeWidgetItem *, int)'),self.makeObjEditorFromTreeItem)

    def update_graph(self):

	cell_name='/cell'
	mc.readCell('mit.p',cell_name)
	self.an=moose.Neutral(cell_name)
	all_ch=self.an.childList 				#all children
	ch = self.get_childrenOfField(all_ch,'Compartment')	#compartments only
	self.coords=[]	
	
	for i in range(0,len(ch),1):
    	    x=float(mc.getField(ch[i],'x'))*(1e+04)
    	    y=float(mc.getField(ch[i],'y'))*(1e+04)
    	    z=float(mc.getField(ch[i],'z'))*(1e+04)
    	    x0=float(mc.getField(ch[i],'x0'))*(1e+04)
    	    y0=float(mc.getField(ch[i],'y0'))*(1e+04)
    	    z0=float(mc.getField(ch[i],'z0'))*(1e+04)
    	    self.coords.append((x0,y0,z0,x,y,z,ch[i].path()))
	
	self.qgl.repaintGL(self.coords)		#checkin all cell compartment diagram entries, sending only the position values
	self.qgl.updateGL()
	self.update_mtree()
    
    def get_childrenOfField(self,all_ch,field):	#'all_ch' is a tuple of moose.id, 'field' is the field to sort with; returns a tuple with valid moose.id's
        ch=[]
        for i in range(0,len(all_ch)):	
	    if(mc.className(all_ch[i])==field):
	        ch.append(all_ch[i])
        return tuple(ch)   

    def update_mtree(self):			#calls the moosetree upper right corner from MooseTree.py the moosetreewidget
	self.mtree.setupTree(self.an,'/',[])
	self.mtree.recreateTree()

    def cmp_position(self,line_label): 		#used with onpickplaceline, returns the absolute value of the end of compartment position
        a_id=mc.pathToId(line_label)
        x= float(mc.getField(a_id,'x'))
        y= float(mc.getField(a_id,'y'))
        z= float(mc.getField(a_id,'z'))	
        return x,y,z

    def select_compartment(self):	
	self.qgl.seltool()

    def makeObjEditorFromTreeItem(self, item, column):
        """Wraps makeObjectFieldEditor for use via a tree item"""
        obj = item.getMooseObject()
        self.makeObjectFieldEditor(obj)	

    def makeObjectFieldEditor(self, obj):
        """Creates a table-editor for a selected object."""
        try:
            self.objFieldEditModel = self.objFieldEditorMap[obj.id]
        except KeyError:
            self.objFieldEditModel = ObjectFieldsModel(obj)
            self.objFieldEditorMap[obj.id] = self.objFieldEditModel
            #self.connect(self.objFieldEditModel, QtCore.SIGNAL('plotWindowChanged(const QString&, const QString&)'), self.changeFieldPlotWidget)
           
	    #if  not hasattr(self, 'objFieldEditPanel'):
            self.mtable.setObjectName(self.tr('MooseObjectFieldEdit'))

            #self.connect(self.objFieldEditModel, QtCore.SIGNAL('objectNameChanged(PyQt_PyObject)'), self.renameObjFieldEditPanel)
            
                
        #self.objFieldEditor = ObjectEditView(self.mtable)
        self.mtable.setObjectName(str(obj.id)) # Assuming Id will not change in the lifetime of the object - something that might break in future version.
        self.mtable.setModel(self.objFieldEditModel)
        self.mtable.setEditTriggers(QtGui.QAbstractItemView.DoubleClicked
                                 | QtGui.QAbstractItemView.SelectedClicked)
        self.mtable.setDragEnabled(True)
        #for plot in self.plots:
        #    objName = plot.objectName()
        #    if objName not in self.objFieldEditModel.plotNames :
        #        self.objFieldEditModel.plotNames += [plot.objectName() for plot in self.plots]
        self.mtable.setItemDelegate(ObjectEditDelegate(self))
        self.connect(self.objFieldEditModel, 
                     QtCore.SIGNAL('objectNameChanged(PyQt_PyObject)'),
                     self.mtree.updateItemSlot)
	if hasattr(self, 'sceneLayout'):
	        self.connect(self.objFieldEditModel, 
        	             QtCore.SIGNAL('objectNameChanged(PyQt_PyObject)'),
        	             self.sceneLayout.updateItemSlot)

        #self.mtable.setWidget(self.objFieldEditor)
        self.mtable.setWindowTitle(self.tr(obj.name))
	self.mtable.show()
	
	
	
	
# create the GUI application
app = QtGui.QApplication(sys.argv)
# instantiate the main window
dmw = DesignerMainWindow()
# show it
dmw.show()
# start the Qt main loop execution, exiting from this script
#http://code.google.com/p/subplot/source/browse/branches/mzViewer/PyMZViewer/mpl_custom_widget.py
#http://eli.thegreenplace.net/files/prog_code/qt_mpl_bars.py.txt
#http://lionel.textmalaysia.com/a-simple-tutorial-on-gui-programming-using-qt-designer-with-pyqt4.html
#http://www.mail-archive.com/matplotlib-users@lists.sourceforge.net/msg13241.html
# with the same return code of Qt application
sys.exit(app.exec_())
